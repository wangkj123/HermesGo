using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Globalization;
using System.IO;
using System.IO.Compression;
using System.Linq;
using System.Net;
using System.Net.Http;
using System.Security.Cryptography;
using System.Text;
using System.Text.RegularExpressions;
using System.Threading;
using System.Threading.Tasks;
using System.Runtime.InteropServices;
using System.Drawing;
using System.Web.Script.Serialization;
using System.Windows.Forms;

internal static class Program
{
    [STAThread]
    private static int Main(string[] args)
    {
        try
        {
            var bootstrap = new HermesBootstrap(AppContext.BaseDirectory, args);
            bootstrap.RunAsync().GetAwaiter().GetResult();
            return 0;
        }
        catch (Exception ex)
        {
            try
            {
                File.AppendAllText(
                    Path.Combine(AppContext.BaseDirectory, "logs", "update", "HermesGo-bootstrap.log"),
                    string.Format("[{0:yyyy-MM-dd HH:mm:ss}] fatal: {1}{2}", DateTime.Now, ex, Environment.NewLine),
                    Encoding.UTF8);
            }
            catch
            {
                // Ignore logging failures; the launcher should still exit cleanly.
            }

            return 1;
        }
    }
}

internal sealed class HermesBootstrap
{
    private const int SwRestore = 9;
    private const string Repo = "NousResearch/hermes-agent";
    private const string AssetName = "HermesGo.zip";
    private const string LocalVersionOverrideEnv = "HERMESGO_LOCAL_VERSION_OVERRIDE";
    private const string ForceUpdateEnv = "HERMESGO_FORCE_UPDATE";
    private const string SkipUpdateEnv = "HERMESGO_SKIP_UPDATE";
    private const string UpdateVersionEnv = "HERMESGO_UPDATE_VERSION";
    private const string UpdateSourcesEnv = "HERMESGO_UPDATE_SOURCES";
    private const string UpdateTimeoutEnv = "HERMESGO_UPDATE_TIMEOUT_SEC";
    private const string UseProxyEnv = "HERMESGO_UPDATE_USE_PROXY";
    private const byte VkControl = 0x11;
    private const byte VkShift = 0x10;
    private const byte VkTab = 0x09;
    private const byte VkW = 0x57;
    private const int KeyeventfKeyup = 0x0002;
    private const int ProbeSampleBytes = 512 * 1024;
    private const int ChunkSizeBytes = 512 * 1024;

    private readonly string _root;
    private readonly string[] _args;
    private readonly string _pythonExe;
    private readonly string _runtimeDir;
    private readonly string _runtimeBinDir;
    private readonly string _homeDir;
    private readonly string _ollamaModelsDir;
    private readonly string _logPath;
    private readonly string _tmpRoot;
    private readonly string _historyPath;

    public HermesBootstrap(string root, string[] args)
    {
        _root = root.TrimEnd(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar);
        _args = args ?? new string[0];
        _pythonExe = Path.Combine(_root, "runtime", "python311", "python.exe");
        _runtimeDir = Path.Combine(_root, "runtime", "hermes-agent");
        _runtimeBinDir = Path.Combine(_root, "runtime", "bin");
        _homeDir = Path.Combine(_root, "home");
        _ollamaModelsDir = Path.Combine(_root, "data", "ollama", "models");
        _logPath = Path.Combine(_root, "logs", "update", "HermesGo-bootstrap.log");
        _tmpRoot = Path.Combine(_root, "logs", "update", "_tmp");
        _historyPath = Path.Combine(_root, "logs", "update", "HermesGo-source-history.log");
    }

    public async Task RunAsync()
    {
        EnsureDirectories();
        CleanupTempArtifacts();

        if (IsSkipped())
        {
            Log("update skipped by environment");
            LaunchEntryPoint();
            return;
        }

        var localVersion = GetLocalVersion();
        var targetVersion = await ResolveTargetVersionAsync().ConfigureAwait(false);
        if (targetVersion == null)
        {
            Log("target version unavailable; launching package without update");
            LaunchEntryPoint();
            return;
        }

        if (!ShouldUpdate(localVersion, targetVersion))
        {
            Log("package already at " + localVersion + "; launching without update");
            LaunchEntryPoint();
            return;
        }

        Log("update needed: local=" + localVersion + ", target=" + targetVersion);

        var sources = BuildSources(targetVersion);
        if (sources.Count == 0)
        {
            Log("no update sources configured; launching package without update");
            LaunchEntryPoint();
            return;
        }

        if (!ContainsFileSource(sources) && ContainsHttpSources(sources))
        {
            if (!await HasNetworkAsync(sources).ConfigureAwait(false))
            {
                Log("network probe failed; launching package without update");
                LaunchEntryPoint();
                return;
            }
        }

        var result = await DownloadConsensusAsync(sources, targetVersion).ConfigureAwait(false);
        if (result == null)
        {
            Log("no valid update package found; launching package without update");
            LaunchEntryPoint();
            return;
        }

        var extractedRoot = ExtractPackage(result.ZipPath, targetVersion);
        if (extractedRoot == null)
        {
            Log("downloaded package failed validation; launching package without update");
            LaunchEntryPoint();
            return;
        }

        ApplyUpdate(extractedRoot);
        CleanupTempArtifacts();
        Log("update applied from " + result.SourceLabel + " (" + result.Md5 + ")");

        LaunchEntryPoint();
    }

    private void EnsureDirectories()
    {
        Directory.CreateDirectory(Path.GetDirectoryName(_logPath) ?? _root);
        Directory.CreateDirectory(_tmpRoot);
    }

    private bool IsSkipped()
    {
        return ReadBoolEnv(SkipUpdateEnv, defaultValue: false);
    }

    private Version GetLocalVersion()
    {
        var overrideValue = Environment.GetEnvironmentVariable(LocalVersionOverrideEnv);
        Version overrideVersion;
        if (!string.IsNullOrWhiteSpace(overrideValue) && Version.TryParse(StripVersionPrefix(overrideValue.Trim()), out overrideVersion))
        {
            Log("local version override: " + overrideVersion);
            return overrideVersion;
        }

        var versionFile = Path.Combine(_root, "runtime", "hermes-agent", "hermes_cli", "__init__.py");
        if (!File.Exists(versionFile))
        {
            return new Version(0, 0, 0);
        }

        var content = File.ReadAllText(versionFile, Encoding.UTF8);
        var match = Regex.Match(content, @"__version__\s*=\s*[""'](?<v>[^""']+)[""']", RegexOptions.Multiline);
        if (!match.Success)
        {
            return new Version(0, 0, 0);
        }

        var versionText = StripVersionPrefix(match.Groups["v"].Value.Trim());
        Version parsed;
        return Version.TryParse(versionText, out parsed) ? parsed : new Version(0, 0, 0);
    }

    private async Task<Version> ResolveTargetVersionAsync()
    {
        var overrideValue = Environment.GetEnvironmentVariable(UpdateVersionEnv);
        Version overridden;
        if (!string.IsNullOrWhiteSpace(overrideValue) && Version.TryParse(StripVersionPrefix(overrideValue.Trim()), out overridden))
        {
            Log("target version override: " + overridden);
            return overridden;
        }

        try
        {
            using (var client = CreateHttpClient())
            {
                var request = new HttpRequestMessage(HttpMethod.Get, string.Format("https://api.github.com/repos/{0}/releases/latest", Repo));
                request.Headers.UserAgent.ParseAdd("HermesGoBootstrap/1.0");
                request.Headers.Accept.ParseAdd("application/vnd.github+json");
                request.Headers.TryAddWithoutValidation("X-GitHub-Api-Version", "2022-11-28");

                using (var response = await client.SendAsync(request).ConfigureAwait(false))
                {
                    if (!response.IsSuccessStatusCode)
                    {
                        Log("latest release probe failed: " + response.StatusCode);
                        return null;
                    }

                    var json = await response.Content.ReadAsStringAsync().ConfigureAwait(false);
                    var match = Regex.Match(json, @"""tag_name""\s*:\s*""(?<v>[^""]+)""", RegexOptions.IgnoreCase);
                    if (!match.Success)
                    {
                        Log("latest release payload missing tag_name");
                        return null;
                    }

                    var tag = StripVersionPrefix(match.Groups["v"].Value.Trim());
                    Version version;
                    if (!Version.TryParse(tag, out version))
                    {
                        Log("latest release tag is not a semver version: " + tag);
                        return null;
                    }

                    Log("latest release from GitHub: " + version);
                    return version;
                }
            }
        }
        catch (Exception ex)
        {
            Log("latest release probe failed: " + ex.Message);
            return null;
        }
    }

    private bool ShouldUpdate(Version localVersion, Version targetVersion)
    {
        if (ReadBoolEnv(ForceUpdateEnv, defaultValue: false))
        {
            Log("force update enabled");
            return true;
        }

        return targetVersion > localVersion;
    }

    private List<UpdateSource> BuildSources(Version targetVersion)
    {
        var configured = Environment.GetEnvironmentVariable(UpdateSourcesEnv);
        if (!string.IsNullOrWhiteSpace(configured))
        {
            var entries = configured
                .Split(new[] { ';', '\r', '\n' }, StringSplitOptions.RemoveEmptyEntries)
                .Select(s => s.Trim())
                .Where(s => s.Length > 0)
                .Select((value, index) => new UpdateSource(value, string.Format("env-{0}", index + 1)))
                .ToList();
            Log("update sources from env: " + entries.Count);
            return entries;
        }

        var version = targetVersion.ToString();
        var tag = "v" + version;
        var owner = "NousResearch";
        var project = "hermes-agent";
        var candidates = new List<UpdateSource>
        {
            new UpdateSource(string.Format("https://mirrors.aliyun.com/github/releases/{0}/{1}/{2}/{3}", owner, project, tag, AssetName), "aliyun-versioned"),
            new UpdateSource(string.Format("https://mirrors.aliyun.com/github/releases/{0}/{1}/LatestRelease/{2}", owner, project, AssetName), "aliyun-latest"),
            new UpdateSource(string.Format("https://mirrors.tuna.tsinghua.edu.cn/github-release/{0}/{1}/{2}/{3}", owner, project, tag, AssetName), "tuna-versioned"),
            new UpdateSource(string.Format("https://mirrors.tuna.tsinghua.edu.cn/github-release/{0}/{1}/LatestRelease/{2}", owner, project, AssetName), "tuna-latest"),
            new UpdateSource(string.Format("https://github.com/{0}/releases/download/{1}/{2}", Repo, tag, AssetName), "github-versioned"),
            new UpdateSource(string.Format("https://github.com/{0}/releases/latest/download/{1}", Repo, AssetName), "github-latest"),
        };

        Log("default update sources: " + candidates.Count);
        return candidates;
    }

    private bool ContainsHttpSources(IEnumerable<UpdateSource> sources)
    {
        return sources.Any(s => s.Uri.Scheme == Uri.UriSchemeHttp || s.Uri.Scheme == Uri.UriSchemeHttps);
    }

    private bool ContainsFileSource(IEnumerable<UpdateSource> sources)
    {
        return sources.Any(s => s.Uri.IsFile || File.Exists(s.Raw));
    }

    private async Task<bool> HasNetworkAsync(IReadOnlyCollection<UpdateSource> sources)
    {
        var firstHttp = sources.FirstOrDefault(s => s.Uri.Scheme == Uri.UriSchemeHttp || s.Uri.Scheme == Uri.UriSchemeHttps);
        if (firstHttp == null)
        {
            return true;
        }

        try
        {
            using (var client = CreateHttpClient())
            using (var request = new HttpRequestMessage(HttpMethod.Head, firstHttp.Uri))
            using (var cts = new CancellationTokenSource(TimeSpan.FromSeconds(4)))
            {
                request.Headers.UserAgent.ParseAdd("HermesGoBootstrap/1.0");
                using (var response = await client.SendAsync(request, cts.Token).ConfigureAwait(false))
                {
                    Log("network probe ok: " + firstHttp.Label + " -> " + (int)response.StatusCode);
                    return true;
                }
            }
        }
        catch (Exception ex)
        {
            Log("network probe failed: " + ex.Message);
            return false;
        }
    }

    private HttpClient CreateHttpClient()
    {
        var handler = new HttpClientHandler
        {
            UseProxy = ReadBoolEnv(UseProxyEnv, defaultValue: false),
            Proxy = null,
            AutomaticDecompression = DecompressionMethods.GZip | DecompressionMethods.Deflate,
        };

        var client = new HttpClient(handler, disposeHandler: true)
        {
            Timeout = TimeSpan.FromSeconds(ReadIntEnv(UpdateTimeoutEnv, 20))
        };
        client.DefaultRequestHeaders.UserAgent.ParseAdd("HermesGoBootstrap/1.0");
        return client;
    }

    private async Task<DownloadConsensus> DownloadConsensusAsync(IReadOnlyCollection<UpdateSource> sources, Version targetVersion)
    {
        Directory.CreateDirectory(_tmpRoot);
        var tempDir = Path.Combine(_tmpRoot, string.Format("download-{0:yyyyMMddHHmmssfff}-{1:N}", DateTime.UtcNow, Guid.NewGuid()));
        Directory.CreateDirectory(tempDir);

        var probes = await ProbeSourcesAsync(sources).ConfigureAwait(false);
        var ranked = probes
            .Where(p => p.Reachable)
            .OrderByDescending(p => p.IsLocal)
            .ThenByDescending(p => p.Score)
            .ThenByDescending(p => p.ContentLength)
            .ThenBy(p => p.Source.Label, StringComparer.OrdinalIgnoreCase)
            .ToList();

        foreach (var probe in ranked)
        {
            Log("source rank: " + probe.Source.Label
                + " local=" + probe.IsLocal
                + " range=" + probe.SupportsRange
                + " bytes=" + probe.ContentLength
                + " sample=" + probe.SampleBytes
                + " elapsedMs=" + probe.Elapsed.TotalMilliseconds.ToString("0")
                + " score=" + probe.Score.ToString("0.00"));
            RecordSourceHistory(probe);
        }

        if (ranked.Count == 0)
        {
            Log("all update sources failed probe");
            SafeDeleteDirectory(tempDir);
            return null;
        }

        var selectedProbe = ranked[0];
        var dest = Path.Combine(tempDir, "HermesGo.zip");
        var adaptiveOk = false;
        if (selectedProbe.CanChunk && selectedProbe.ContentLength > 0)
        {
            adaptiveOk = await DownloadAdaptiveAsync(ranked, dest).ConfigureAwait(false);
        }

        if (!adaptiveOk)
        {
            Log("adaptive chunked download unavailable or failed; falling back to ranked full downloads");
            foreach (var probe in ranked)
            {
                var result = await DownloadOneAsync(probe.Source, targetVersion, tempDir, 0).ConfigureAwait(false);
                if (result.Success)
                {
                    Log("download ok: " + result.SourceLabel + " md5=" + result.Md5 + " size=" + result.Bytes);
                    return new DownloadConsensus(tempDir, result.ZipPath, result.SourceLabel, result.Md5, result.Bytes);
                }
            }

            Log("all ranked download sources failed");
            SafeDeleteDirectory(tempDir);
            return null;
        }

        if (!IsValidZip(dest))
        {
            Log("adaptive download produced invalid zip archive");
            SafeDeleteDirectory(tempDir);
            return null;
        }

        var md5 = ComputeMd5(dest);
        var bytes = new FileInfo(dest).Length;
        Log("selected package: " + selectedProbe.Source.Label + " md5=" + md5);
        return new DownloadConsensus(tempDir, dest, selectedProbe.Source.Label, md5, bytes);
    }

    private async Task<List<SourceProbe>> ProbeSourcesAsync(IReadOnlyCollection<UpdateSource> sources)
    {
        var tasks = sources.Select(ProbeSourceAsync).ToArray();
        var results = await Task.WhenAll(tasks).ConfigureAwait(false);
        return results.ToList();
    }

    private async Task<SourceProbe> ProbeSourceAsync(UpdateSource source)
    {
        if (source.Uri.IsFile || File.Exists(source.Raw))
        {
            var filePath = source.Uri.IsFile ? source.Uri.LocalPath : source.Raw;
            if (!File.Exists(filePath))
            {
                return SourceProbe.Failed(source, "local source not found");
            }

            var info = new FileInfo(filePath);
            return SourceProbe.Local(source, info.Length);
        }

        var probeLimit = ProbeSampleBytes;
        try
        {
            using (var client = CreateHttpClient())
            using (var request = new HttpRequestMessage(HttpMethod.Get, source.Uri))
            {
                request.Headers.TryAddWithoutValidation("Range", "bytes=0-" + (probeLimit - 1));
                var sw = Stopwatch.StartNew();
                using (var response = await client.SendAsync(request, HttpCompletionOption.ResponseHeadersRead).ConfigureAwait(false))
                {
                    if (!response.IsSuccessStatusCode && response.StatusCode != HttpStatusCode.PartialContent)
                    {
                        return SourceProbe.Failed(source, "probe status " + (int)response.StatusCode);
                    }

                    var contentLength = GetResponseLength(response);
                    var supportsRange = response.StatusCode == HttpStatusCode.PartialContent;
                    using (var stream = await response.Content.ReadAsStreamAsync().ConfigureAwait(false))
                    {
                        var sample = await ReadUpToAsync(stream, probeLimit).ConfigureAwait(false);
                        sw.Stop();
                        var elapsed = sw.Elapsed;
                        return SourceProbe.Probed(source, supportsRange, contentLength, sample.Length, elapsed, (int)response.StatusCode);
                    }
                }
            }
        }
        catch (Exception ex)
        {
            return SourceProbe.Failed(source, ex.Message);
        }
    }

    private async Task<bool> DownloadAdaptiveAsync(IReadOnlyList<SourceProbe> ranked, string dest)
    {
        var lengthProbe = ranked.FirstOrDefault(p => p.ContentLength > 0);
        if (lengthProbe == null)
        {
            return false;
        }

        var expectedLength = lengthProbe.ContentLength;

        try
        {
            using (var target = new FileStream(dest, FileMode.Create, FileAccess.Write, FileShare.None))
            {
                target.SetLength(expectedLength);
                var active = ranked.ToList();
                long offset = 0;
                while (offset < expectedLength)
                {
                    var chunkSize = (int)Math.Min(ChunkSizeBytes, expectedLength - offset);
                    var chunk = await DownloadChunkFromRankedSourcesAsync(active, target, offset, chunkSize).ConfigureAwait(false);
                    if (!chunk.Success)
                    {
                        return false;
                    }

                    offset += chunk.Bytes;
                }
            }

            return true;
        }
        catch (Exception ex)
        {
            Log("adaptive download failed: " + ex.Message);
            return false;
        }
    }

    private async Task<ChunkDownloadResult> DownloadChunkFromRankedSourcesAsync(List<SourceProbe> ranked, FileStream target, long offset, int chunkSize)
    {
        for (var index = 0; index < ranked.Count; index++)
        {
            var probe = ranked[index];
            if (!probe.CanChunk)
            {
                continue;
            }

            try
            {
                var sw = Stopwatch.StartNew();
                var chunk = await ReadChunkAsync(probe, offset, chunkSize).ConfigureAwait(false);
                sw.Stop();

                if (chunk == null || chunk.Length != chunkSize)
                {
                    throw new IOException("short chunk");
                }

                target.Seek(offset, SeekOrigin.Begin);
                target.Write(chunk, 0, chunk.Length);

                var elapsed = sw.Elapsed;
                probe.RecordChunk(chunk.Length, elapsed);
                if (index > 0)
                {
                    ranked.RemoveAt(index);
                    ranked.Insert(0, probe);
                    Log("source promoted: " + probe.Source.Label);
                }

                return ChunkDownloadResult.Successful(probe, chunk.Length, elapsed);
            }
            catch (Exception ex)
            {
                probe.RecordFailure();
                Log("chunk download failed: " + probe.Source.Label + " offset=" + offset + " size=" + chunkSize + " err=" + ex.Message);
                continue;
            }
        }

        return ChunkDownloadResult.Failed();
    }

    private async Task<byte[]> ReadChunkAsync(SourceProbe probe, long offset, int chunkSize)
    {
        if (probe.Source.Uri.IsFile || File.Exists(probe.Source.Raw))
        {
            var filePath = probe.Source.Uri.IsFile ? probe.Source.Uri.LocalPath : probe.Source.Raw;
            using (var stream = new FileStream(filePath, FileMode.Open, FileAccess.Read, FileShare.ReadWrite))
            {
                stream.Seek(offset, SeekOrigin.Begin);
                return await ReadExactAsync(stream, chunkSize).ConfigureAwait(false);
            }
        }

        using (var client = CreateHttpClient())
        using (var request = new HttpRequestMessage(HttpMethod.Get, probe.Source.Uri))
        {
            request.Headers.TryAddWithoutValidation("Range", "bytes=" + offset + "-" + (offset + chunkSize - 1));
            using (var response = await client.SendAsync(request, HttpCompletionOption.ResponseHeadersRead).ConfigureAwait(false))
            {
                if (response.StatusCode != HttpStatusCode.PartialContent)
                {
                    throw new IOException("unexpected chunk status " + (int)response.StatusCode);
                }

                using (var stream = await response.Content.ReadAsStreamAsync().ConfigureAwait(false))
                {
                    return await ReadExactAsync(stream, chunkSize).ConfigureAwait(false);
                }
            }
        }
    }

    private async Task<byte[]> ReadUpToAsync(Stream stream, int maxBytes)
    {
        var buffer = new byte[maxBytes];
        var total = 0;
        while (total < maxBytes)
        {
            var read = await stream.ReadAsync(buffer, total, maxBytes - total).ConfigureAwait(false);
            if (read <= 0)
            {
                break;
            }
            total += read;
        }

        if (total == buffer.Length)
        {
            return buffer;
        }

        var trimmed = new byte[total];
        Buffer.BlockCopy(buffer, 0, trimmed, 0, total);
        return trimmed;
    }

    private async Task<byte[]> ReadExactAsync(Stream stream, int size)
    {
        var buffer = new byte[size];
        var total = 0;
        while (total < size)
        {
            var read = await stream.ReadAsync(buffer, total, size - total).ConfigureAwait(false);
            if (read <= 0)
            {
                break;
            }
            total += read;
        }

        if (total != size)
        {
            throw new EndOfStreamException("expected " + size + " bytes, got " + total);
        }

        return buffer;
    }

    private long GetResponseLength(HttpResponseMessage response)
    {
        if (response.Content != null && response.Content.Headers != null)
        {
            var range = response.Content.Headers.ContentRange;
            if (range != null && range.Length.HasValue)
            {
                return range.Length.Value;
            }

            if (response.Content.Headers.ContentLength.HasValue)
            {
                return response.Content.Headers.ContentLength.Value;
            }
        }

        return -1;
    }

    private async Task<DownloadResult> DownloadOneAsync(UpdateSource source, Version targetVersion, string tempDir, int index)
    {
        var dest = Path.Combine(tempDir, string.Format("{0:00}-{1}.zip", index, SanitizeFileName(source.Label)));
        var attempts = 3;
        for (var attempt = 1; attempt <= attempts; attempt++)
        {
            var shouldRetry = false;
            try
            {
                if (source.Uri.IsFile || File.Exists(source.Raw))
                {
                    var filePath = source.Uri.IsFile ? source.Uri.LocalPath : source.Raw;
                    if (!File.Exists(filePath))
                    {
                        throw new FileNotFoundException("local source not found: " + filePath);
                    }

                    File.Copy(filePath, dest, overwrite: true);
                }
                else
                {
                    await DownloadHttpAsync(source.Uri, dest).ConfigureAwait(false);
                }

                if (!IsValidZip(dest))
                {
                    throw new InvalidDataException("downloaded file is not a valid zip archive");
                }

                var md5 = ComputeMd5(dest);
                var bytes = new FileInfo(dest).Length;
                return new DownloadResult(source.Label, dest, md5, bytes, success: true);
            }
            catch (Exception ex)
            {
                Log("download failed: " + source.Label + " attempt=" + attempt + "/" + attempts + " err=" + ex.Message);
                try
                {
                    if (File.Exists(dest))
                    {
                        File.Delete(dest);
                    }
                }
                catch
                {
                    // Ignore cleanup failures.
                }

                if (attempt < attempts)
                {
                    shouldRetry = true;
                }
            }

            if (shouldRetry)
            {
                await Task.Delay(TimeSpan.FromSeconds(attempt)).ConfigureAwait(false);
            }
        }

        return new DownloadResult(source.Label, dest, string.Empty, 0, success: false);
    }

    private async Task DownloadHttpAsync(Uri uri, string dest)
    {
        using (var client = CreateHttpClient())
        {
            using (var response = await client.GetAsync(uri, HttpCompletionOption.ResponseHeadersRead).ConfigureAwait(false))
            {
                response.EnsureSuccessStatusCode();

                using (var source = await response.Content.ReadAsStreamAsync().ConfigureAwait(false))
                using (var target = new FileStream(dest, FileMode.Create, FileAccess.Write, FileShare.None))
                {
                    await source.CopyToAsync(target).ConfigureAwait(false);
                }
            }
        }
    }

    private bool IsValidZip(string path)
    {
        try
        {
            using (var archive = ZipFile.OpenRead(path))
            {
                return archive.Entries.Count > 0;
            }
        }
        catch
        {
            return false;
        }
    }

    private string ComputeMd5(string path)
    {
        using (var md5 = MD5.Create())
        using (var stream = File.OpenRead(path))
        {
            var hash = md5.ComputeHash(stream);
            var builder = new StringBuilder(hash.Length * 2);
            foreach (var b in hash)
            {
                builder.Append(b.ToString("x2", CultureInfo.InvariantCulture));
            }
            return builder.ToString();
        }
    }

    private string ExtractPackage(string zipPath, Version targetVersion)
    {
        var stagingDir = Path.Combine(_tmpRoot, string.Format("extract-{0:yyyyMMddHHmmssfff}-{1:N}", DateTime.UtcNow, Guid.NewGuid()));
        Directory.CreateDirectory(stagingDir);

        try
        {
            using (var archive = ZipFile.OpenRead(zipPath))
            {
                foreach (var entry in archive.Entries)
                {
                    if (string.IsNullOrWhiteSpace(entry.FullName))
                    {
                        continue;
                    }

                    var normalized = entry.FullName.Replace('\\', '/').TrimStart('/');
                    if (normalized.EndsWith("/", StringComparison.Ordinal))
                    {
                        continue;
                    }

                    var destination = Path.Combine(stagingDir, normalized.Replace('/', Path.DirectorySeparatorChar));
                    Directory.CreateDirectory(Path.GetDirectoryName(destination) ?? stagingDir);
                    entry.ExtractToFile(destination, overwrite: true);
                }
            }

            var root = FindExtractedRoot(stagingDir);
            if (root == null)
            {
                Log("extracted package root not found");
                SafeDeleteDirectory(stagingDir);
                return null;
            }

            if (!ValidatePackageRoot(root))
            {
                Log("extracted package root failed validation");
                SafeDeleteDirectory(stagingDir);
                return null;
            }

            Log("staged package ready for " + targetVersion);
            return root;
        }
        catch (Exception ex)
        {
            Log("package extraction failed: " + ex.Message);
            SafeDeleteDirectory(stagingDir);
            return null;
        }
    }

    private string FindExtractedRoot(string stagingDir)
    {
        // If the archive contains a single top-level folder, use it.
        var childDirs = Directory.GetDirectories(stagingDir);
        var childFiles = Directory.GetFiles(stagingDir);
        if (childDirs.Length == 1 && childFiles.Length == 0)
        {
            return childDirs[0];
        }

        return stagingDir;
    }

    private bool ValidatePackageRoot(string packageRoot)
    {
        var required = new[]
        {
            Path.Combine(packageRoot, "HermesGo.exe"),
            Path.Combine(packageRoot, "HermesGo.bat"),
            Path.Combine(packageRoot, "Start-HermesGo.ps1"),
            Path.Combine(packageRoot, "runtime", "hermes-agent", "hermes_cli", "__init__.py"),
        };

        return required.All(File.Exists);
    }

    private void ApplyUpdate(string extractedRoot)
    {
        var preserveRoots = new HashSet<string>(StringComparer.OrdinalIgnoreCase)
        {
            "home",
            "data",
            "logs",
        };

        foreach (var file in Directory.GetFiles(extractedRoot, "*", SearchOption.AllDirectories))
        {
            var relative = GetRelativePath(extractedRoot, file);
            if (ShouldSkipPath(relative, preserveRoots))
            {
                continue;
            }

            if (IsSelfExe(relative))
            {
                continue;
            }

            var destination = Path.Combine(_root, relative);
            Directory.CreateDirectory(Path.GetDirectoryName(destination) ?? _root);
            File.Copy(file, destination, overwrite: true);
        }
    }

    private bool ShouldSkipPath(string relativePath, HashSet<string> preserveRoots)
    {
        var normalized = relativePath.Replace('\\', '/');
        var top = normalized.Split('/').FirstOrDefault() ?? string.Empty;
        return preserveRoots.Contains(top);
    }

    private bool IsSelfExe(string relativePath)
    {
        var normalized = relativePath.Replace('\\', '/');
        return normalized.Equals("HermesGo.exe", StringComparison.OrdinalIgnoreCase);
    }

    private static string GetRelativePath(string basePath, string fullPath)
    {
        var baseUri = new Uri(AppendDirectorySeparatorChar(Path.GetFullPath(basePath)));
        var fullUri = new Uri(Path.GetFullPath(fullPath));
        var relativeUri = baseUri.MakeRelativeUri(fullUri);
        var relativePath = Uri.UnescapeDataString(relativeUri.ToString());
        return relativePath.Replace('/', Path.DirectorySeparatorChar);
    }

    private static string AppendDirectorySeparatorChar(string path)
    {
        if (path.EndsWith(Path.DirectorySeparatorChar.ToString(), StringComparison.Ordinal) ||
            path.EndsWith(Path.AltDirectorySeparatorChar.ToString(), StringComparison.Ordinal))
        {
            return path;
        }

        return path + Path.DirectorySeparatorChar;
    }

    private void LaunchEntryPoint()
    {
        if (ShouldSkipLauncher())
        {
            LaunchPackage(_args);
            return;
        }

        if (_args.Length > 0)
        {
            LaunchPackage(_args);
            return;
        }

        ShowClassicLauncher();
    }

    private bool ShouldSkipLauncher()
    {
        return ReadBoolEnv("HERMESGO_SKIP_LAUNCHER", defaultValue: false);
    }

    private void ShowClassicLauncher()
    {
        if (!Environment.UserInteractive)
        {
            LaunchPackage(new string[0]);
            return;
        }

        Application.EnableVisualStyles();
        Application.SetCompatibleTextRenderingDefault(false);

        var launcherState = GetLauncherState();

        using (var form = new LauncherForm(launcherState))
        {
            form.BeginnerRequested += delegate
            {
                RunLauncherActionAsync(form, HandleBeginnerLaunch);
            };
            form.CloudRequested += delegate
            {
                RunLauncherActionAsync(form, HandleCloudLaunch);
            };
            form.ExpertRequested += delegate
            {
                RunLauncherActionAsync(form, HandleExpertLaunch);
            };
            form.SwitchModelRequested += delegate
            {
                RunLauncherActionAsync(form, HandleSwitchModelLaunch);
            };
            form.VerifyRequested += delegate
            {
                RunLauncherActionAsync(form, HandleVerifyLaunch);
            };
            form.CodexLoginRequested += delegate
            {
                RunLauncherActionAsync(form, HandleCodexLoginLaunch);
            };
            form.OpenHomeRequested += delegate
            {
                OpenFolder(_homeDir);
                form.Close();
            };
            form.OpenLogsRequested += delegate
            {
                OpenFolder(Path.Combine(_root, "logs"));
                form.Close();
            };
            form.OpenCustomActionsRequested += delegate
            {
                OpenTextFile(Path.Combine(_homeDir, "launcher-actions.txt"));
                form.Close();
            };
            form.CustomActionRequested += delegate (object sender, LauncherForm.LauncherOption option)
            {
                RunLauncherActionAsync(form, delegate { return HandleCustomLauncherAction(option); });
            };
            form.ExitRequested += delegate
            {
                form.Close();
            };

            Application.Run(form);
        }
    }

    private void RunLauncherActionAsync(LauncherForm form, Func<bool> action)
    {
        if (form == null || action == null)
        {
            return;
        }

        form.Enabled = false;
        form.UseWaitCursor = true;

        Task.Run(() =>
        {
            var shouldClose = false;
            try
            {
                shouldClose = action();
            }
            catch (Exception ex)
            {
                WriteLauncherGuidance("HermesGo 启动器错误", ex.Message);
            }

            try
            {
                if (form.IsHandleCreated)
                {
                    form.BeginInvoke(new Action(() =>
                    {
                        form.UseWaitCursor = false;
                        form.Enabled = true;
                        if (shouldClose && !form.IsDisposed)
                        {
                            form.Close();
                        }
                    }));
                }
            }
            catch
            {
                // Best effort only.
            }
        });
    }

    private bool HandleBeginnerLaunch()
    {
        ApplyLocalPreset();
        LaunchPackage(new string[0]);
        return true;
    }

    private bool HandleCloudLaunch()
    {
        return HandleCloudLaunch(
            "gpt-5.4-mini",
            "https://chatgpt.com/backend-api/codex",
            "http://127.0.0.1:9119/env?oauth=openai-codex");
    }

    private bool HandleCloudLaunch(string model, string baseUrl, string browserUrl)
    {
        var state = GetLauncherState();
        var loggedInDuringThisLaunch = false;
        if (!state.HasCodexAuth)
        {
            if (!HandleCodexLoginLaunch())
            {
                return false;
            }

            loggedInDuringThisLaunch = true;
            state = GetLauncherState();
            if (!state.HasCodexAuth)
            {
                WriteLauncherGuidance(
                    "Codex 登录未成功",
                    "当前还没有可用的 openai-codex 凭据，请先完成登录后再点“Cloud: GPT-5.4 Mini”。");
                return false;
            }
        }

        ApplyConfigPreset("openai-codex", model, baseUrl);
        LaunchPackage(new[] { "-NoOpenBrowser", "-OAuthProvider", "openai-codex" });

        if (!WaitForUrlReady(browserUrl, TimeSpan.FromSeconds(45)))
        {
            WriteLauncherGuidance(
                "Dashboard 未就绪",
                "后台已经启动，但 Dashboard 还没有准备好。请先检查日志，或者稍后再点“Cloud: GPT-5.4 Mini”。");
            return false;
        }

        OpenUrl(browserUrl);
        if (loggedInDuringThisLaunch)
        {
            ClosePreviousBrowserTabIfNeeded();
        }

        Log("Cloud 启动已完成 - 已确认 Codex 登录状态并打开 dashboard。");
        return true;
    }

    private bool HandleExpertLaunch()
    {
        LaunchPackage(new[] { "-NoOpenChat" });
        return true;
    }

    private bool HandleSwitchModelLaunch()
    {
        var exitCode = RunBlockingScript("Switch-HermesGoModel.ps1");
        if (exitCode != 0)
        {
            WriteLauncherGuidance(
                "本地模型切换未完成",
                "切换脚本没有正常结束。请先完成本地模型配置，再重新选择“Utility: Switch Local Model”。");
            return false;
        }

        LaunchPackage(new string[0]);
        return true;
    }

    private bool HandleVerifyLaunch()
    {
        LaunchBatchScript("Verify-HermesGo.bat");
        return true;
    }

        private bool HandleCodexLoginLaunch()
        {
            if (HasValidCodexAuth())
            {
                Log("Codex 登录已就绪 - 跳过登录流程，直接继续启动。");
                return true;
            }

            var exitCode = RunBlockingCodexLoginCommand("login");
            if (exitCode != 0)
            {
                WriteLauncherGuidance(
                    "Codex 登录未完成",
                    "登录流程已经结束，但没有拿到有效授权。请先完成浏览器登录，再重新点“Utility: Codex Login”或“Cloud: GPT-5.4 Mini”。");
                return false;
            }

            var state = GetLauncherState();
            if (!state.HasCodexAuth)
            {
                WriteLauncherGuidance(
                    "Codex 登录已结束，但状态未刷新",
                    "请确认浏览器里的登录已经成功，然后重新打开启动器再试一次。");
                return false;
            }

            Log("Codex 登录成功 - 已写入 HermesGo 的 auth.json。");
            return true;
        }

    private bool HandleCustomLauncherAction(LauncherForm.LauncherOption option)
    {
        if (option == null)
        {
            return false;
        }

        var kind = (option.Kind ?? string.Empty).Trim().ToLowerInvariant();
        if (kind == "preset")
        {
            var values = ParseLauncherValuePairs(option.Value);
            string provider;
            string model;
            string baseUrl;
            if (!values.TryGetValue("provider", out provider))
            {
                provider = "ollama";
            }
            if (!values.TryGetValue("model", out model))
            {
                model = "gemma:2b";
            }
            if (!values.TryGetValue("baseUrl", out baseUrl) && !values.TryGetValue("base_url", out baseUrl))
            {
                baseUrl = string.Equals(provider, "openai-codex", StringComparison.OrdinalIgnoreCase)
                    ? "https://chatgpt.com/backend-api/codex"
                    : "http://127.0.0.1:11434/v1";
            }

            if (string.Equals(provider, "openai-codex", StringComparison.OrdinalIgnoreCase))
            {
                if (!HandleCloudLaunch(
                    model,
                    baseUrl,
                    "http://127.0.0.1:9119/env?oauth=openai-codex"))
                {
                    return false;
                }
                return true;
            }

            if (string.Equals(provider, "ollama", StringComparison.OrdinalIgnoreCase))
            {
                ApplyModelPreset(provider, model, baseUrl);
                LaunchPackage(new string[0]);
                return true;
            }

            ApplyConfigPreset(provider, model, baseUrl);
            LaunchPackage(new[] { "-OAuthProvider", provider });
            return true;
        }

        if (kind == "script")
        {
            var scriptValue = option.Value ?? string.Empty;
            var scriptParts = scriptValue.Split(new[] { ' ' }, 2, StringSplitOptions.RemoveEmptyEntries);
            var scriptName = scriptParts.Length > 0 ? scriptParts[0] : string.Empty;
            var scriptArgs = scriptParts.Length > 1 ? new[] { scriptParts[1] } : null;
            LaunchBatchScript(scriptName, scriptArgs);
            return true;
        }

        if (kind == "folder")
        {
            OpenFolder(option.Value);
            return true;
        }

        if (kind == "url")
        {
            OpenUrl(option.Value);
            return true;
        }

        Log("custom launcher action ignored: " + option.Text + " kind=" + kind);
        return false;
    }

    private void WriteLauncherGuidance(string title, string message)
    {
        Log(title + " - " + message);
        try
        {
            MessageBox.Show(message, title, MessageBoxButtons.OK, MessageBoxIcon.Information);
        }
        catch
        {
            // Guidance is best effort only.
        }
    }

    private void ApplyLocalPreset()
    {
        ApplyModelPreset(
            provider: "ollama",
            model: "gemma:2b",
            baseUrl: "http://127.0.0.1:11434/v1");
        Log("launcher preset applied: local model gemma:2b");
    }

    private void ApplyCloudPreset()
    {
        ApplyConfigPreset(
            provider: "openai-codex",
            model: "gpt-5.4-mini",
            baseUrl: "https://chatgpt.com/backend-api/codex");
        Log("launcher preset applied: openai-codex gpt-5.4-mini");
    }

        private LauncherState GetLauncherState()
        {
            var state = new LauncherState
            {
                Provider = "ollama",
            Model = "gemma:2b",
            BaseUrl = "http://127.0.0.1:11434/v1",
            HasCodexAuth = HasValidCodexAuth(),
        };

        var configPath = Path.Combine(_homeDir, "config.yaml");
        if (!File.Exists(configPath))
        {
            return state;
        }

        try
        {
            var config = File.ReadAllText(configPath, Encoding.UTF8);
            var provider = ReadYamlScalar(config, "provider");
            var model = ReadYamlScalar(config, "default");
            var baseUrl = ReadYamlScalar(config, "base_url");

            if (!string.IsNullOrWhiteSpace(provider))
            {
                state.Provider = provider.Trim();
            }
            if (!string.IsNullOrWhiteSpace(model))
            {
                state.Model = model.Trim();
            }
            if (!string.IsNullOrWhiteSpace(baseUrl))
            {
                state.BaseUrl = baseUrl.Trim();
            }
        }
        catch
        {
            // Keep the fallback summary if the config is unreadable.
        }

        state.IsLocalPreset = string.Equals(state.Provider, "ollama", StringComparison.OrdinalIgnoreCase)
            && string.Equals(state.Model, "gemma:2b", StringComparison.OrdinalIgnoreCase);
        state.IsCloudPreset = string.Equals(state.Provider, "openai-codex", StringComparison.OrdinalIgnoreCase)
            && string.Equals(state.Model, "gpt-5.4-mini", StringComparison.OrdinalIgnoreCase);

            return state;
        }

        private List<string> GetCodexAuthCandidatePaths()
        {
            var paths = new List<string>();

            Action<string> addPath = delegate (string path)
            {
                if (string.IsNullOrWhiteSpace(path))
                {
                    return;
                }

                var normalized = path.Trim();
                if (!paths.Exists(delegate (string existing)
                {
                    return string.Equals(existing, normalized, StringComparison.OrdinalIgnoreCase);
                }))
                {
                    paths.Add(normalized);
                }
            };

            addPath(Path.Combine(_homeDir, "auth.json"));
            addPath(Path.Combine(_homeDir, "codex", "auth.json"));

            return paths;
        }

        private bool HasValidCodexTokensInFile(string authPath)
        {
            if (string.IsNullOrWhiteSpace(authPath) || !File.Exists(authPath))
            {
                return false;
            }

            try
            {
                var serializer = new JavaScriptSerializer();
                var raw = serializer.DeserializeObject(File.ReadAllText(authPath, Encoding.UTF8)) as Dictionary<string, object>;
                if (raw == null)
                {
                    return false;
                }

                if (HasValidCodexTokenBlock(raw))
                {
                    return true;
                }

                object providersObj;
                if (raw.TryGetValue("providers", out providersObj))
                {
                    var providers = providersObj as Dictionary<string, object>;
                    if (providers != null)
                    {
                        object codexObj;
                        if (providers.TryGetValue("openai-codex", out codexObj))
                        {
                            var codex = codexObj as Dictionary<string, object>;
                            if (HasValidCodexTokenBlock(codex))
                            {
                                return true;
                            }
                        }
                    }
                }
            }
            catch
            {
                // Ignore malformed auth files and keep probing the other locations.
            }

            return false;
        }

        private static bool HasValidCodexTokenBlock(Dictionary<string, object> block)
        {
            if (block == null)
            {
                return false;
            }

            object tokensObj;
            if (!block.TryGetValue("tokens", out tokensObj))
            {
                return false;
            }

            var tokens = tokensObj as Dictionary<string, object>;
            if (tokens == null)
            {
                return false;
            }

            var accessToken = tokens.ContainsKey("access_token") ? tokens["access_token"] as string : null;
            var refreshToken = tokens.ContainsKey("refresh_token") ? tokens["refresh_token"] as string : null;
            return !string.IsNullOrWhiteSpace(accessToken) && !string.IsNullOrWhiteSpace(refreshToken);
        }

        private bool HasValidCodexAuth()
        {
            foreach (var authPath in GetCodexAuthCandidatePaths())
            {
                if (HasValidCodexTokensInFile(authPath))
                {
                    return true;
                }
            }

            return false;
        }

    private static string ReadYamlScalar(string content, string key)
    {
        var match = Regex.Match(
            content ?? string.Empty,
            @"(?m)^\s*" + Regex.Escape(key) + @"\s*:\s*""?(?<v>[^""\r\n]+)""?\s*$");
        return match.Success ? match.Groups["v"].Value : string.Empty;
    }

    private void ApplyModelPreset(string provider, string model, string baseUrl)
    {
        Directory.CreateDirectory(_homeDir);

        var portableDefaultsPath = Path.Combine(_homeDir, "portable-defaults.txt");
        var portableDefaults = string.Join(Environment.NewLine, new[]
        {
            "; Portable fallback defaults for HermesGo",
            "DEFAULT_OLLAMA_PROVIDER=" + provider,
            "DEFAULT_OLLAMA_MODEL=" + model,
            "DEFAULT_OLLAMA_BASE_URL=" + baseUrl,
            string.Empty,
        });
        File.WriteAllText(portableDefaultsPath, portableDefaults, Encoding.UTF8);

        ApplyConfigPreset(provider, model, baseUrl);
    }

    private void ApplyConfigPreset(string provider, string model, string baseUrl)
    {
        Directory.CreateDirectory(_homeDir);

        var configPath = Path.Combine(_homeDir, "config.yaml");
        string configText;
        if (File.Exists(configPath))
        {
            configText = File.ReadAllText(configPath, Encoding.UTF8);
        }
        else
        {
            configText = string.Join(Environment.NewLine, new[]
            {
                "model:",
                "  default: \"gemma:2b\"",
                "  provider: \"ollama\"",
                "  base_url: \"http://127.0.0.1:11434/v1\"",
                string.Empty,
                "terminal:",
                "  backend: \"local\"",
                "  cwd: \".\"",
                "  timeout: 180",
                "  lifetime_seconds: 300",
                string.Empty,
            });
        }

        configText = UpdateYamlScalar(configText, "default", model);
        configText = UpdateYamlScalar(configText, "provider", provider);
        configText = UpdateYamlScalar(configText, "base_url", baseUrl);
        File.WriteAllText(configPath, configText, Encoding.UTF8);
    }

    private void LaunchBatchScript(string scriptName, string[] args = null)
    {
        var scriptPath = Path.Combine(_root, scriptName);
        if (!File.Exists(scriptPath))
        {
            Log("utility script not found: " + scriptPath);
            return;
        }

        var batchArgs = new List<string> { "/k", Quote(scriptPath) };
        if (args != null)
        {
            foreach (var arg in args)
            {
                batchArgs.Add(Quote(arg));
            }
        }

        var psi = new ProcessStartInfo
        {
            FileName = "cmd.exe",
            Arguments = string.Join(" ", batchArgs),
            WorkingDirectory = _root,
            UseShellExecute = false,
            CreateNoWindow = false,
            WindowStyle = ProcessWindowStyle.Normal,
        };

        Process.Start(psi);
        Log("launched utility script: " + scriptName);
    }

    private void OpenFolder(string path)
    {
        if (string.IsNullOrWhiteSpace(path))
        {
            return;
        }

        var psi = new ProcessStartInfo
        {
            FileName = "explorer.exe",
            Arguments = Quote(path),
            WorkingDirectory = _root,
            UseShellExecute = false,
            CreateNoWindow = false,
            WindowStyle = ProcessWindowStyle.Normal,
        };

        Process.Start(psi);
        Log("opened folder: " + path);
    }

    private void OpenTextFile(string path)
    {
        if (string.IsNullOrWhiteSpace(path))
        {
            return;
        }

        if (!File.Exists(path))
        {
            Log("text file not found: " + path);
            return;
        }

        var psi = new ProcessStartInfo
        {
            FileName = path,
            WorkingDirectory = _root,
            UseShellExecute = true,
        };

        Process.Start(psi);
        Log("opened text file: " + path);
    }

    private int RunBlockingScript(string scriptName, string[] args = null)
    {
        var scriptPath = Path.Combine(_root, scriptName);
        if (!File.Exists(scriptPath))
        {
            Log("blocking utility script not found: " + scriptPath);
            return 1;
        }

        var ext = Path.GetExtension(scriptPath).ToLowerInvariant();
        ProcessStartInfo psi;
        if (ext == ".ps1")
        {
            psi = new ProcessStartInfo
            {
                FileName = "powershell.exe",
                Arguments = BuildPowerShellArguments(scriptPath, args),
                WorkingDirectory = _root,
                UseShellExecute = false,
                CreateNoWindow = false,
                WindowStyle = ProcessWindowStyle.Normal,
            };
        }
        else
        {
            var batchArgs = new List<string> { "/c", Quote(scriptPath) };
            if (args != null)
            {
                foreach (var arg in args)
                {
                    batchArgs.Add(Quote(arg));
                }
            }

            psi = new ProcessStartInfo
            {
                FileName = "cmd.exe",
                Arguments = string.Join(" ", batchArgs),
                WorkingDirectory = _root,
                UseShellExecute = false,
                CreateNoWindow = false,
                WindowStyle = ProcessWindowStyle.Normal,
            };
        }

        using (var process = Process.Start(psi))
        {
            if (process == null)
            {
                throw new InvalidOperationException("Unable to start script: " + scriptName);
            }

            process.WaitForExit();
            return process.ExitCode;
        }
    }

    private int RunBlockingPythonCommand(string command)
    {
        if (!File.Exists(_pythonExe))
        {
            Log("python runtime not found: " + _pythonExe);
            return 1;
        }

        var psi = new ProcessStartInfo
        {
            FileName = _pythonExe,
            Arguments = "-c " + Quote(command),
            WorkingDirectory = _root,
            UseShellExecute = false,
            CreateNoWindow = false,
            WindowStyle = ProcessWindowStyle.Normal,
        };

        ApplyInteractiveEnvironment(psi);

        using (var process = Process.Start(psi))
        {
            if (process == null)
            {
                throw new InvalidOperationException("Unable to start python command.");
            }

            process.WaitForExit();
            return process.ExitCode;
        }
    }

    private int RunBlockingCodexLoginCommand(string command)
    {
        var codexCmd = Path.Combine(_root, "codex.cmd");
        if (!File.Exists(codexCmd))
        {
            Log("codex compatibility launcher not found: " + codexCmd);
            return 1;
        }

        var loginStdout = Path.Combine(_root, "logs", "update", "codex-login.out.txt");
        var loginStderr = Path.Combine(_root, "logs", "update", "codex-login.err.txt");
        Directory.CreateDirectory(Path.GetDirectoryName(loginStdout) ?? _root);
        File.WriteAllText(loginStdout, string.Empty, new UTF8Encoding(false));
        File.WriteAllText(loginStderr, string.Empty, new UTF8Encoding(false));

        var psi = new ProcessStartInfo
        {
            FileName = "cmd.exe",
            Arguments = "/c " + Quote(codexCmd) + (string.IsNullOrWhiteSpace(command) ? string.Empty : " " + command),
            WorkingDirectory = _root,
            UseShellExecute = false,
            CreateNoWindow = true,
            WindowStyle = ProcessWindowStyle.Hidden,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            StandardOutputEncoding = Encoding.UTF8,
            StandardErrorEncoding = Encoding.UTF8,
        };

        ApplyInteractiveEnvironment(psi);

        using (var process = Process.Start(psi))
        {
            if (process == null)
            {
                throw new InvalidOperationException("Unable to start codex login command.");
            }

            var stdout = process.StandardOutput.ReadToEndAsync();
            var stderr = process.StandardError.ReadToEndAsync();
            process.WaitForExit();
            File.WriteAllText(loginStdout, stdout.GetAwaiter().GetResult() ?? string.Empty, new UTF8Encoding(false));
            File.WriteAllText(loginStderr, stderr.GetAwaiter().GetResult() ?? string.Empty, new UTF8Encoding(false));
            Log("codex login command finished: exit=" + process.ExitCode);
            return process.ExitCode;
        }
    }

    private static Dictionary<string, string> ParseLauncherValuePairs(string value)
    {
        var result = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
        var segments = (value ?? string.Empty).Split(new[] { ';' }, StringSplitOptions.RemoveEmptyEntries);
        foreach (var segment in segments)
        {
            var pair = segment.Split(new[] { '=' }, 2);
            if (pair.Length != 2)
            {
                continue;
            }

            var key = pair[0].Trim();
            var val = pair[1].Trim();
            if (key.Length == 0)
            {
                continue;
            }

            result[key] = val;
        }

        return result;
    }

    private void RunCustomLauncherAction(LauncherForm.LauncherOption option)
    {
        if (option == null)
        {
            return;
        }

        var kind = (option.Kind ?? string.Empty).Trim().ToLowerInvariant();
        if (kind == "preset")
        {
            var values = ParseLauncherValuePairs(option.Value);
            string provider;
            string model;
            string baseUrl;
            if (!values.TryGetValue("provider", out provider))
            {
                provider = "ollama";
            }
            if (!values.TryGetValue("model", out model))
            {
                model = "gemma:2b";
            }
            if (!values.TryGetValue("baseUrl", out baseUrl) && !values.TryGetValue("base_url", out baseUrl))
            {
                baseUrl = "http://127.0.0.1:11434/v1";
            }

            if (string.Equals(provider, "ollama", StringComparison.OrdinalIgnoreCase))
            {
                ApplyModelPreset(provider, model, baseUrl);
                LaunchPackage(new string[0]);
            }
            else
            {
                ApplyConfigPreset(provider, model, baseUrl);
                LaunchPackage(new[] { "-NoOpenChat", "-OAuthProvider", provider });
            }
            return;
        }

        if (kind == "script")
        {
            var scriptValue = option.Value ?? string.Empty;
            var scriptParts = scriptValue.Split(new[] { ' ' }, 2, StringSplitOptions.RemoveEmptyEntries);
            var scriptName = scriptParts.Length > 0 ? scriptParts[0] : string.Empty;
            var scriptArgs = scriptParts.Length > 1 ? new[] { scriptParts[1] } : null;
            LaunchBatchScript(scriptName, scriptArgs);
            return;
        }

        if (kind == "folder")
        {
            OpenFolder(option.Value);
            return;
        }

        if (kind == "url")
        {
            OpenUrl(option.Value);
            return;
        }

        Log("custom launcher action ignored: " + option.Text + " kind=" + kind);
    }

    private void OpenUrl(string url)
    {
        if (string.IsNullOrWhiteSpace(url))
        {
            return;
        }

        var psi = new ProcessStartInfo
        {
            FileName = url,
            UseShellExecute = true,
        };

        Process.Start(psi);
        Log("opened url: " + url);
        BringKnownBrowserToFront();
    }

    private bool ClosePreviousBrowserTabIfNeeded()
    {
        if (!BringKnownBrowserToFront())
        {
            return false;
        }

        try
        {
            keybd_event(VkControl, 0, 0, IntPtr.Zero);
            keybd_event(VkShift, 0, 0, IntPtr.Zero);
            keybd_event(VkTab, 0, 0, IntPtr.Zero);
            Thread.Sleep(80);
            keybd_event(VkTab, 0, KeyeventfKeyup, IntPtr.Zero);
            keybd_event(VkShift, 0, KeyeventfKeyup, IntPtr.Zero);
            keybd_event(VkControl, 0, KeyeventfKeyup, IntPtr.Zero);
            Thread.Sleep(120);
            keybd_event(VkControl, 0, 0, IntPtr.Zero);
            keybd_event(VkW, 0, 0, IntPtr.Zero);
            Thread.Sleep(80);
            keybd_event(VkW, 0, KeyeventfKeyup, IntPtr.Zero);
            keybd_event(VkControl, 0, KeyeventfKeyup, IntPtr.Zero);
            Log("closed previous browser tab after Codex login");
            return true;
        }
        catch (Exception ex)
        {
            Log("failed to close previous browser tab: " + ex.Message);
            return false;
        }
    }

    [DllImport("user32.dll")]
    private static extern bool SetForegroundWindow(IntPtr hWnd);

    [DllImport("user32.dll")]
    private static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);

    [DllImport("user32.dll")]
    private static extern void keybd_event(byte bVk, byte bScan, int dwFlags, IntPtr dwExtraInfo);

    private static readonly string[] BrowserProcessNames =
    {
        "msedge",
        "chrome",
        "firefox",
        "brave",
        "opera",
        "vivaldi",
    };

    private bool BringKnownBrowserToFront()
    {
        for (var attempt = 0; attempt < 10; attempt++)
        {
            foreach (var name in BrowserProcessNames)
            {
                Process[] processes;
                try
                {
                    processes = Process.GetProcessesByName(name);
                }
                catch
                {
                    continue;
                }

                foreach (var process in processes)
                {
                    try
                    {
                        if (process.MainWindowHandle == IntPtr.Zero)
                        {
                            continue;
                        }

                        ShowWindow(process.MainWindowHandle, SwRestore);
                        SetForegroundWindow(process.MainWindowHandle);
                        Log("browser brought to front: " + name);
                        return true;
                    }
                    catch
                    {
                        // Try the next browser process.
                    }
                }
            }

            Thread.Sleep(300);
        }

        return false;
    }

    private bool WaitForUrlReady(string url, TimeSpan timeout)
    {
        var deadline = DateTime.UtcNow.Add(timeout);
        using (var client = new HttpClient())
        {
            while (DateTime.UtcNow < deadline)
            {
                try
                {
                    using (var response = client.GetAsync(url).GetAwaiter().GetResult())
                    {
                        if (response.IsSuccessStatusCode)
                        {
                            return true;
                        }
                    }
                }
                catch
                {
                    // Retry until timeout.
                }

                Thread.Sleep(500);
            }
        }

        return false;
    }

    private static string UpdateYamlScalar(string content, string key, string value)
    {
        var escaped = (value ?? string.Empty)
            .Replace("\\", "\\\\")
            .Replace("\"", "\\\"");
        var pattern = @"(?m)^(\s*" + Regex.Escape(key) + @":\s*).*$";
        var replacement = "$1\"" + escaped + "\"";
        return Regex.Replace(content ?? string.Empty, pattern, replacement);
    }

    private void ApplyInteractiveEnvironment(ProcessStartInfo psi)
    {
        var noProxyDefaults = new[]
        {
            "localhost",
            "127.0.0.1",
            "::1",
            "0.0.0.0",
            ".local",
            ".localhost",
            ".cn",
            ".com.cn",
            ".net.cn",
            ".org.cn",
            ".edu.cn",
            ".gov.cn",
            ".mil.cn",
            ".ac.cn",
            ".npmmirror.com",
            ".aliyun.com",
            ".aliyuncs.com",
            ".tuna.tsinghua.edu.cn",
            ".sdu.edu.cn",
            ".ustc.edu.cn",
        };
        var merged = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        AddNoProxyEntries(merged, Environment.GetEnvironmentVariable("NO_PROXY"));
        AddNoProxyEntries(merged, Environment.GetEnvironmentVariable("no_proxy"));
        foreach (var entry in noProxyDefaults)
        {
            merged.Add(entry);
        }

        psi.EnvironmentVariables["PYTHONHOME"] = string.Empty;
        psi.EnvironmentVariables["PYTHONPATH"] = _runtimeDir;
        psi.EnvironmentVariables["PATH"] = string.Join(";", new[]
        {
            _root,
            _runtimeBinDir,
            Environment.GetEnvironmentVariable("PATH") ?? string.Empty,
        });
        psi.EnvironmentVariables["HERMES_HOME"] = _homeDir;
        psi.EnvironmentVariables["OLLAMA_MODELS"] = _ollamaModelsDir;
        psi.EnvironmentVariables["PYTHONUTF8"] = "1";
        psi.EnvironmentVariables["PYTHONIOENCODING"] = "utf-8";
        psi.EnvironmentVariables["NO_PROXY"] = string.Join(",", merged);
        psi.EnvironmentVariables["no_proxy"] = string.Join(",", merged);
    }

    private static void AddNoProxyEntries(HashSet<string> merged, string value)
    {
        if (string.IsNullOrWhiteSpace(value))
        {
            return;
        }

        var parts = value.Split(new[] { ',', ';' }, StringSplitOptions.RemoveEmptyEntries);
        foreach (var part in parts)
        {
            var trimmed = part.Trim();
            if (trimmed.Length > 0)
            {
                merged.Add(trimmed);
            }
        }
    }

    private void LaunchPackage(string[] args)
    {
        var script = Path.Combine(_root, "Start-HermesGo.ps1");
        var batch = Path.Combine(_root, "HermesGo.bat");
        var useScript = File.Exists(script);
        var fileName = useScript ? "powershell.exe" : "cmd.exe";
        var arguments = useScript
            ? BuildPowerShellArguments(script, args)
            : BuildBatchArguments(batch, args);

        var psi = new ProcessStartInfo
        {
            FileName = fileName,
            Arguments = arguments,
            WorkingDirectory = _root,
            UseShellExecute = false,
            CreateNoWindow = false,
            WindowStyle = ProcessWindowStyle.Normal,
        };

        Process.Start(psi);
        Log(useScript ? "launched Start-HermesGo.ps1" : "launched HermesGo.bat");
    }

    private string BuildPowerShellArguments(string script, string[] args)
    {
        var builder = new StringBuilder();
        builder.Append("-NoLogo -NoProfile -ExecutionPolicy Bypass -File ");
        builder.Append(Quote(script));
        foreach (var arg in args)
        {
            builder.Append(' ');
            builder.Append(Quote(arg));
        }
        return builder.ToString();
    }

    private string BuildBatchArguments(string batch, string[] args)
    {
        var joined = string.Join(" ", args.Select(Quote));
        return "/c " + Quote(batch) + (joined.Length > 0 ? " " + joined : string.Empty);
    }

    private static string Quote(string value)
    {
        if (string.IsNullOrEmpty(value))
        {
            return "\"\"";
        }

        if (value.IndexOfAny(new[] { ' ', '\t', '"', '&', '(', ')', '^' }) >= 0)
        {
            return "\"" + value.Replace("\"", "\\\"") + "\"";
        }

        return value;
    }

    private sealed class LauncherState
    {
        public string Provider { get; set; }
        public string Model { get; set; }
        public string BaseUrl { get; set; }
        public bool HasCodexAuth { get; set; }
        public bool IsLocalPreset { get; set; }
        public bool IsCloudPreset { get; set; }
    }

    private sealed class LauncherForm : Form
    {
        public sealed class LauncherOption
        {
            public string Key { get; set; }
            public string Text { get; set; }
            public string Description { get; set; }
            public string Kind { get; set; }
            public string Value { get; set; }
            public bool IsCustom { get; set; }

            public override string ToString()
            {
                return Text;
            }
        }

        public event EventHandler BeginnerRequested;
        public event EventHandler CloudRequested;
        public event EventHandler ExpertRequested;
        public event EventHandler SwitchModelRequested;
        public event EventHandler VerifyRequested;
        public event EventHandler CodexLoginRequested;
        public event EventHandler OpenHomeRequested;
        public event EventHandler OpenLogsRequested;
        public event EventHandler OpenCustomActionsRequested;
        public event EventHandler<LauncherOption> CustomActionRequested;
        public event EventHandler ExitRequested;

        private ComboBox _selectionBox;
        private Button _executeSelectionButton;
        private Button _helpButton;
        private Label _selectionDescription;
        private readonly LauncherState _launcherState;
        private readonly List<LauncherOption> _launcherOptions = new List<LauncherOption>();

        public LauncherForm(LauncherState state)
        {
            _launcherState = state ?? new LauncherState
            {
                Provider = "ollama",
                Model = "gemma:2b",
                BaseUrl = "http://127.0.0.1:11434/v1",
            };

            Text = "HermesGo 启动器";
            StartPosition = FormStartPosition.CenterScreen;
            FormBorderStyle = FormBorderStyle.FixedDialog;
            MaximizeBox = false;
            MinimizeBox = false;
            ShowInTaskbar = true;
            Width = 920;
            Height = 520;
            BackColor = Color.FromArgb(245, 242, 235);
            Font = new Font("Segoe UI", 10F, FontStyle.Regular, GraphicsUnit.Point);

            try
            {
                var appIcon = Icon.ExtractAssociatedIcon(Application.ExecutablePath);
                if (appIcon != null)
                {
                    Icon = appIcon;
                }
            }
            catch
            {
                // Ignore icon failures; the launcher still works without one.
            }

            var layout = new TableLayoutPanel
            {
                Dock = DockStyle.Fill,
                ColumnCount = 2,
                RowCount = 1,
                Padding = new Padding(18),
                BackColor = BackColor,
            };
            layout.ColumnStyles.Add(new ColumnStyle(SizeType.Absolute, 270F));
            layout.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100F));
            Controls.Add(layout);

            var heroPanel = new Panel
            {
                Dock = DockStyle.Fill,
                BackColor = Color.FromArgb(36, 44, 78),
                Padding = new Padding(18),
            };

            var logo = new PictureBox
            {
                Width = 128,
                Height = 128,
                Left = 24,
                Top = 18,
                SizeMode = PictureBoxSizeMode.Zoom,
                BackColor = Color.Transparent,
                Image = LoadLauncherLogoImage(),
            };

            var heroTitle = new Label
            {
                AutoSize = false,
                Left = 18,
                Top = 160,
                Width = 220,
                Height = 44,
                Font = new Font(Font.FontFamily, 20F, FontStyle.Bold),
                ForeColor = Color.White,
                Text = "HermesGo",
            };

            var heroSubtitle = new Label
            {
                AutoSize = false,
                Left = 18,
                Top = 212,
                Width = 220,
                Height = 96,
                ForeColor = Color.FromArgb(214, 222, 255),
                Text = "新手可以直接一键启动。高手可以进 Dashboard。切换到 GPT-5.4 mini 也可以从这里直接选。",
            };

            var summaryBox = new Panel
            {
                Left = 18,
                Top = 328,
                Width = 220,
                Height = 96,
                BackColor = Color.FromArgb(58, 68, 111),
                Padding = new Padding(12),
            };

            var summaryTitle = new Label
            {
                AutoSize = false,
                Dock = DockStyle.Top,
                Height = 22,
                ForeColor = Color.FromArgb(223, 228, 255),
                Font = new Font(Font.FontFamily, 9.5F, FontStyle.Bold),
                Text = "当前默认",
            };

            var summaryText = new Label
            {
                AutoSize = false,
                Dock = DockStyle.Fill,
                ForeColor = Color.White,
                Text = string.Format("{0} / {1}{2}{3}", _launcherState.Provider, _launcherState.Model, Environment.NewLine, _launcherState.BaseUrl),
            };

            summaryBox.Controls.Add(summaryText);
            summaryBox.Controls.Add(summaryTitle);

            heroPanel.Controls.Add(logo);
            heroPanel.Controls.Add(heroTitle);
            heroPanel.Controls.Add(heroSubtitle);
            heroPanel.Controls.Add(summaryBox);

            var mainPanel = new Panel
            {
                Dock = DockStyle.Fill,
                BackColor = BackColor,
                Padding = new Padding(12, 0, 0, 0),
            };

            var header = new Label
            {
                AutoSize = false,
                Dock = DockStyle.Top,
                Height = 58,
                Font = new Font(Font.FontFamily, 18F, FontStyle.Bold),
                ForeColor = Color.FromArgb(30, 30, 35),
                Text = "请选择一个启动方式",
            };

            var subtitle = new Label
            {
                AutoSize = false,
                Dock = DockStyle.Top,
                Height = 34,
                ForeColor = Color.FromArgb(96, 96, 110),
                Text = "新手点第一项就能用。要用 GPT-5.4 mini 点第二项。要看全部配置和日志点第三项。",
            };

            var actionPanel = new Panel
            {
                Dock = DockStyle.Top,
                Height = 188,
                BackColor = Color.FromArgb(236, 240, 246),
                Padding = new Padding(12),
            };

            var actionTitle = new Label
            {
                AutoSize = false,
                Dock = DockStyle.Top,
                Height = 20,
                ForeColor = Color.FromArgb(70, 72, 80),
                Font = new Font(Font.FontFamily, 10F, FontStyle.Bold),
                Text = "请选择一个启动方式",
            };

            _selectionBox = new ComboBox
            {
                Left = 12,
                Top = 34,
                Width = 352,
                Height = 28,
                DropDownStyle = ComboBoxStyle.DropDownList,
                Font = new Font(Font.FontFamily, 10F, FontStyle.Regular),
            };
            _selectionBox.SelectedIndexChanged += delegate { UpdateSelectionDescription(); };

            _executeSelectionButton = new Button
            {
                Left = 372,
                Top = 32,
                Width = 110,
                Height = 32,
                Text = "启动",
                FlatStyle = FlatStyle.Flat,
                BackColor = Color.FromArgb(44, 120, 228),
                ForeColor = Color.White,
                UseVisualStyleBackColor = false,
            };
            _executeSelectionButton.FlatAppearance.BorderSize = 0;
            _executeSelectionButton.Click += delegate { ExecuteSelectedAction(); };

            _helpButton = new Button
            {
                Left = 492,
                Top = 32,
                Width = 68,
                Height = 32,
                Text = "帮助",
                FlatStyle = FlatStyle.Flat,
                BackColor = Color.FromArgb(106, 106, 118),
                ForeColor = Color.White,
                UseVisualStyleBackColor = false,
                Anchor = AnchorStyles.Top | AnchorStyles.Right,
            };
            _helpButton.FlatAppearance.BorderSize = 0;
            _helpButton.Click += delegate { ShowSelectedActionHelp(); };

            _selectionDescription = new Label
            {
                AutoSize = false,
                Left = 12,
                Top = 72,
                Width = 548,
                Height = 96,
                ForeColor = Color.FromArgb(88, 90, 100),
                Text = "先从上面的菜单选一个动作，再点“启动”。需要更详细的说明时点“帮助”。",
            };
            _selectionDescription.Visible = true;

            actionPanel.Controls.Add(_selectionDescription);
            actionPanel.Controls.Add(_helpButton);
            actionPanel.Controls.Add(_selectionBox);
            actionPanel.Controls.Add(actionTitle);

            var cards = new FlowLayoutPanel
            {
                Dock = DockStyle.Fill,
                AutoScroll = true,
                FlowDirection = FlowDirection.TopDown,
                WrapContents = false,
                Padding = new Padding(0, 10, 12, 0),
            };

            cards.Controls.Add(CreateActionCard(
                "一键启动（本地 2B）",
                "适合新手，保留默认的离线本地模型，不会触发 ChatGPT / Codex 登录，直接打开聊天和浏览器。",
                "启动 HermesGo",
                delegate { OnBeginnerRequested(); },
                Color.FromArgb(44, 120, 228)));

            cards.Controls.Add(CreateActionCard(
                "Cloud: GPT-5.4 Mini",
                "切换到 OpenAI Codex 路线，默认模型改成 gpt-5.4-mini。只有这里在未登录时才会自动运行 bundled 的 codex login。",
                "使用 GPT-5.4 mini",
                delegate { OnCloudRequested(); },
                Color.FromArgb(34, 151, 115)));

            cards.Controls.Add(CreateActionCard(
                "Expert: Dashboard Only",
                "只启动 Dashboard 和后台服务，不主动弹聊天窗口，适合高级用户调参数和看日志。",
                "打开 Dashboard",
                delegate { OnExpertRequested(); },
                Color.FromArgb(158, 87, 27)));

            cards.Controls.Add(CreateActionCard(
                "Utility: Switch Local Model",
                "打开本地模型切换脚本，用来改 Ollama 离线模型，比如 gemma、qwen。",
                "切换本地模型",
                delegate { OnSwitchModelRequested(); },
                Color.FromArgb(124, 84, 26)));

            cards.Controls.Add(CreateActionCard(
                "Utility: Self Check",
                "运行绿色包自检，检查启动器、图标、模型目录、Dashboard 入口和日志是否正常。",
                "开始自检",
                delegate { OnVerifyRequested(); },
                Color.FromArgb(98, 110, 126)));

            cards.Controls.Add(CreateActionCard(
                "Utility: Codex Login",
                "只在你想手动切换或重新授权 OpenAI / Codex 账号时使用。不会影响本地 2B 启动。",
                "登录 Codex",
                delegate { OnCodexLoginRequested(); },
                Color.FromArgb(105, 72, 150)));

            cards.Controls.Add(CreateActionCard(
                "Open: Home Folder",
                "直接打开 home 目录，里面通常放 config.yaml、session、记忆和运行状态文件。",
                "打开 home",
                delegate { OnOpenHomeRequested(); },
                Color.FromArgb(72, 121, 163)));

            cards.Controls.Add(CreateActionCard(
                "Open: Logs Folder",
                "直接打开 logs 目录，方便查看启动日志、更新日志和 Dashboard 日志。",
                "打开 logs",
                delegate { OnOpenLogsRequested(); },
                Color.FromArgb(90, 90, 90)));

            PopulateLauncherOptions(_launcherState);
            cards.Visible = false;
            cards.Height = 0;

            var footer = new Label
            {
                AutoSize = false,
                Dock = DockStyle.Bottom,
                Height = 34,
                ForeColor = Color.FromArgb(110, 110, 120),
                Text = "如果你只是想先能用，点第一项就够了。",
            };

            var exitButton = new Button
            {
                Text = "退出",
                Width = 100,
                Height = 34,
                Dock = DockStyle.Left,
                FlatStyle = FlatStyle.Flat,
                UseVisualStyleBackColor = false,
            };
            exitButton.FlatAppearance.BorderColor = Color.FromArgb(190, 190, 200);
            exitButton.Click += delegate { OnExitRequested(); };

            var footerRow = new Panel
            {
                Dock = DockStyle.Bottom,
                Height = 42,
            };
            _executeSelectionButton.Dock = DockStyle.Right;
            footerRow.Controls.Add(_executeSelectionButton);
            footerRow.Controls.Add(exitButton);

            mainPanel.Controls.Add(cards);
            mainPanel.Controls.Add(actionPanel);
            mainPanel.Controls.Add(footerRow);
            mainPanel.Controls.Add(footer);
            mainPanel.Controls.Add(subtitle);
            mainPanel.Controls.Add(header);

            layout.Controls.Add(heroPanel, 0, 0);
            layout.Controls.Add(mainPanel, 1, 0);

            AcceptButton = _executeSelectionButton;
        }

        private string GetPackageRoot()
        {
            return Path.GetDirectoryName(Application.ExecutablePath) ?? string.Empty;
        }

        private string GetHomeDir()
        {
            return Path.Combine(GetPackageRoot(), "home");
        }

        private string GetLauncherSelectionPath()
        {
            return Path.Combine(GetHomeDir(), "launcher-selected.txt");
        }

        private string GetLauncherActionsPath()
        {
            return Path.Combine(GetHomeDir(), "launcher-actions.txt");
        }

        private void EnsureLauncherActionsTemplate()
        {
            var homeDir = GetHomeDir();
            Directory.CreateDirectory(homeDir);

            var path = GetLauncherActionsPath();
            if (File.Exists(path))
            {
                return;
            }

            var template = string.Join(Environment.NewLine, new[]
            {
                "; HermesGo custom launcher actions",
                "; Format: key|title|description|kind|value",
                "; kind: preset, script, folder, url",
                "; Example:",
                "; custom-qwen|Custom: Qwen 3B|Switch to qwen2.5:3b local model|preset|provider=ollama;model=qwen2.5:3b;baseUrl=http://127.0.0.1:11434/v1",
                "; custom-work|Custom: Open Work Folder|Open your own work folder|folder|E:\\AI\\hermes",
                string.Empty,
            });

            File.WriteAllText(path, template, Encoding.UTF8);
        }

        private string LoadSavedLauncherSelectionKey()
        {
            try
            {
                var path = GetLauncherSelectionPath();
                if (!File.Exists(path))
                {
                    return string.Empty;
                }

                return File.ReadAllText(path, Encoding.UTF8).Trim();
            }
            catch
            {
                return string.Empty;
            }
        }

        private void SaveSelectedLauncherKey(string key)
        {
            try
            {
                Directory.CreateDirectory(GetHomeDir());
                File.WriteAllText(GetLauncherSelectionPath(), key ?? string.Empty, Encoding.UTF8);
            }
            catch
            {
                // Ignore selection persistence failures.
            }
        }

        private static string NormalizeLauncherKey(string value)
        {
            var cleaned = Regex.Replace(value ?? string.Empty, @"[^a-zA-Z0-9]+", "-").Trim('-').ToLowerInvariant();
            return string.IsNullOrWhiteSpace(cleaned) ? "custom" : cleaned;
        }

        private static Dictionary<string, string> ParseLauncherValuePairs(string value)
        {
            var result = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
            var segments = (value ?? string.Empty).Split(new[] { ';' }, StringSplitOptions.RemoveEmptyEntries);
            foreach (var segment in segments)
            {
                var pair = segment.Split(new[] { '=' }, 2);
                if (pair.Length != 2)
                {
                    continue;
                }

                var key = pair[0].Trim();
                var val = pair[1].Trim();
                if (key.Length == 0)
                {
                    continue;
                }

                result[key] = val;
            }

            return result;
        }

        private List<LauncherOption> LoadCustomLauncherOptions()
        {
            EnsureLauncherActionsTemplate();

            var options = new List<LauncherOption>();
            var path = GetLauncherActionsPath();
            if (!File.Exists(path))
            {
                return options;
            }

            string[] lines;
            try
            {
                lines = File.ReadAllLines(path, Encoding.UTF8);
            }
            catch
            {
                return options;
            }

            foreach (var rawLine in lines)
            {
                var line = (rawLine ?? string.Empty).Trim();
                if (line.Length == 0 || line.StartsWith(";") || line.StartsWith("#"))
                {
                    continue;
                }

                var parts = line.Split(new[] { '|' }, 5);
                if (parts.Length < 4)
                {
                    continue;
                }

                var key = NormalizeLauncherKey(parts[0]);
                var title = parts[1].Trim();
                var description = parts[2].Trim();
                var kind = parts[3].Trim().ToLowerInvariant();
                var value = parts.Length >= 5 ? parts[4].Trim() : string.Empty;

                if (title.Length == 0)
                {
                    continue;
                }

                options.Add(new LauncherOption
                {
                    Key = "custom:" + key,
                    Text = title,
                    Description = description,
                    Kind = kind,
                    Value = value,
                    IsCustom = true,
                });
            }

            return options;
        }

        private void PopulateLauncherOptions(LauncherState state)
        {
            _launcherOptions.Clear();

            var builtIns = new List<LauncherOption>();
            builtIns.Add(new LauncherOption
            {
                Key = "beginner",
                Text = "Beginner: Local Start",
                Description = "作用：保留默认的本地 Ollama 2B 模式，直接启动 HermesGo 的聊天流程，适合第一次使用的人。\r\n怎么用：选中后点“启动”，程序会先检查本地默认配置，再打开常规聊天界面和浏览器窗口。\r\n适合谁：只想尽快能用，不想先改模型、不想碰复杂配置的用户。",
                Kind = "beginner",
            });
            builtIns.Add(new LauncherOption
            {
                Key = "cloud",
                Text = "Cloud: GPT-5.4 Mini",
                Description = "作用：把当前包切到 OpenAI Codex 路线，默认模型改成 gpt-5.4-mini。已登录时直接继续启动，未登录时才打开浏览器里的 Codex 登录页。\r\n怎么用：选中后点“启动”。如果还没登录，启动器会先带你走登录流程；登录成功后再继续切到云端模型。\r\n适合谁：想用云端模型、需要更强能力、愿意做在线登录的用户。",
                Kind = "cloud",
            });
            builtIns.Add(new LauncherOption
            {
                Key = "expert",
                Text = "Expert: Dashboard Only",
                Description = "作用：只启动 Dashboard 和后台服务，不主动弹聊天窗口，便于高级用户自己调参数和看日志。\r\n怎么用：选中后点“启动”，浏览器会直接进入配置页。你可以在 Dashboard 里切模型、看状态、改路径、查日志。\r\n适合谁：已经知道自己在干什么的人，或者需要排查问题的人。",
                Kind = "expert",
            });
            builtIns.Add(new LauncherOption
            {
                Key = "switch-model",
                Text = "Utility: Switch Local Model",
                Description = "作用：打开本地模型切换脚本，用来改 Ollama 离线模型，比如 gemma、qwen 这类本地模型。\r\n怎么用：如果你要换离线模型，就选这个项。脚本会单独打开一个窗口，让你按提示选择要切到哪个本地模型，然后写入本地配置。\r\n适合谁：离线使用者，或者还在用本地 2B 模型但想换其他本地模型的人。",
                Kind = "switch-model",
            });
            builtIns.Add(new LauncherOption
            {
                Key = "verify",
                Text = "Utility: Self Check",
                Description = "作用：运行绿色包自检，检查启动器、图标、模型目录、Dashboard 入口和日志是否正常。\r\n怎么用：更新完包以后先跑这个项。它会帮你确认文件结构有没有问题，适合在正式发给别人之前做最后确认。\r\n适合谁：打包维护者、测试人员、想确认包是否完整的人。",
                Kind = "verify",
            });
            builtIns.Add(new LauncherOption
            {
                Key = "codex-login",
                Text = "Utility: Codex Login",
                Description = "作用：运行 bundled 的 codex login，给 HermesGo 写入 OpenAI / Codex 的授权状态。\r\n怎么用：如果你要用云端能力，先选这个项完成登录。登录成功后再回到 Cloud: GPT-5.4 Mini 或 Dashboard 继续启动。\r\n适合谁：需要登录 OpenAI 账号，但不想手动找命令行的人。",
                Kind = "codex-login",
            });
            builtIns.Add(new LauncherOption
            {
                Key = "open-home",
                Text = "Open: Home Folder",
                Description = "作用：直接打开 home 目录，里面通常放 config.yaml、session、记忆和运行状态文件。\r\n怎么用：如果你要人工查看配置，就选这个项。打开后可以直接看文件，不需要手动去找路径。\r\n适合谁：需要检查配置文件、备份状态、或手工排错的人。",
                Kind = "open-home",
            });
            builtIns.Add(new LauncherOption
            {
                Key = "open-logs",
                Text = "Open: Logs Folder",
                Description = "作用：直接打开 logs 目录，方便查看启动日志、更新日志和 Dashboard 日志。\r\n怎么用：遇到启动失败、模型切换失败或浏览器没打开时，先点这个项，再看最新日志文件。\r\n适合谁：排查问题的人，或者想确认程序有没有正常运行的人。",
                Kind = "open-logs",
            });
            builtIns.Add(new LauncherOption
            {
                Key = "open-custom-actions",
                Text = "Open: Custom Actions File",
                Description = "作用：直接打开自定义动作文件，方便你新增自己的启动类型。\r\n怎么用：先点这个项，再编辑 home\\launcher-actions.txt。下一次启动时，文件里的自定义动作会自动出现在菜单里。\r\n适合谁：想自己扩展启动器的人。",
                Kind = "open-custom-actions",
            });

            _launcherOptions.AddRange(builtIns);
            _launcherOptions.AddRange(LoadCustomLauncherOptions());

            var savedKey = LoadSavedLauncherSelectionKey();
            _selectionBox.Items.Clear();
            var orderedOptions = new List<LauncherOption>(_launcherOptions);
            var defaultKey = string.Equals(state != null ? state.Provider : string.Empty, "openai-codex", StringComparison.OrdinalIgnoreCase)
                ? "cloud"
                : "beginner";
            var preferredKey = string.IsNullOrWhiteSpace(savedKey) ? defaultKey : savedKey;
            var selected = orderedOptions.FirstOrDefault(item => string.Equals(item.Key, preferredKey, StringComparison.OrdinalIgnoreCase))
                ?? orderedOptions.FirstOrDefault();
            if (selected != null)
            {
                orderedOptions.Remove(selected);
                orderedOptions.Insert(0, selected);
            }

            foreach (var option in orderedOptions)
            {
                _selectionBox.Items.Add(option);
            }

            _selectionBox.SelectedItem = selected;
            UpdateSelectionDescription();
        }

        private LauncherOption GetSelectedLauncherOption()
        {
            return _selectionBox != null ? _selectionBox.SelectedItem as LauncherOption : null;
        }

        private void UpdateSelectionDescription()
        {
            if (_selectionDescription == null)
            {
                return;
            }

            var option = GetSelectedLauncherOption();
            _selectionDescription.Text = option != null ? BuildSelectionDescription(option) : string.Empty;
        }

        private void ExecuteSelectedAction()
        {
            var option = GetSelectedLauncherOption();
            if (option == null)
            {
                return;
            }

            SaveSelectedLauncherKey(option.Key);

            switch (option.Key)
            {
                case "beginner":
                    OnBeginnerRequested();
                    return;
                case "cloud":
                    OnCloudRequested();
                    return;
                case "expert":
                    OnExpertRequested();
                    return;
                case "switch-model":
                    OnSwitchModelRequested();
                    return;
                case "verify":
                    OnVerifyRequested();
                    return;
                case "codex-login":
                    OnCodexLoginRequested();
                    return;
                case "open-home":
                    OnOpenHomeRequested();
                    return;
                case "open-logs":
                    OnOpenLogsRequested();
                    return;
                case "open-custom-actions":
                    OnOpenCustomActionsRequested();
                    return;
            }

            if (option.IsCustom)
            {
                OnCustomActionRequested(option);
            }
        }

        private void ShowSelectedActionHelp()
        {
            var option = GetSelectedLauncherOption();
            if (option == null)
            {
                MessageBox.Show(
                    this,
                    "请先从上面的菜单选一个动作，再点“帮助”。",
                    "选择项帮助",
                    MessageBoxButtons.OK,
                    MessageBoxIcon.Information);
                return;
            }

            var message = string.Format("{0}{1}{1}{2}", option.Text, Environment.NewLine, BuildSelectionDescription(option));
            MessageBox.Show(
                this,
                message,
                "选择项帮助",
                MessageBoxButtons.OK,
                MessageBoxIcon.Information);
        }

        private string BuildSelectionDescription(LauncherOption option)
        {
            var lines = new List<string>();
            lines.Add(option.Description);

            var statusLines = BuildSelectionStatusLines(option);
            if (statusLines.Count > 0)
            {
                lines.Add(string.Empty);
                lines.Add("当前检测：");
                lines.AddRange(statusLines);
            }

            return string.Join(Environment.NewLine, lines.ToArray());
        }

        private List<string> BuildSelectionStatusLines(LauncherOption option)
        {
            var lines = new List<string>();
            var state = _launcherState ?? new LauncherState();
            var provider = (state.Provider ?? string.Empty).Trim();
            var model = (state.Model ?? string.Empty).Trim();
            var baseUrl = (state.BaseUrl ?? string.Empty).Trim();

            lines.Add(string.Format("provider: {0}", string.IsNullOrWhiteSpace(provider) ? "(空)" : provider));
            lines.Add(string.Format("model: {0}", string.IsNullOrWhiteSpace(model) ? "(空)" : model));
            lines.Add(string.Format("base_url: {0}", string.IsNullOrWhiteSpace(baseUrl) ? "(空)" : baseUrl));

            if (string.Equals(option.Key, "beginner", StringComparison.OrdinalIgnoreCase))
            {
                lines.Add(state.IsLocalPreset
                    ? "当前状态：本地默认配置已就绪，直接启动即可。"
                    : "当前状态：不是本地默认配置，点“启动”后会先写回本地 2B 配置，再启动。");
            }
            else if (string.Equals(option.Key, "cloud", StringComparison.OrdinalIgnoreCase))
            {
                lines.Add(state.HasCodexAuth
                    ? "Codex 登录：已就绪。"
                    : "Codex 登录：未就绪，点“启动”会先打开登录流程。");
                lines.Add(state.IsCloudPreset
                    ? "当前状态：Cloud 默认配置已对齐。"
                    : "当前状态：会先把模型切到 gpt-5.4-mini 再启动。");
            }
            else if (string.Equals(option.Key, "expert", StringComparison.OrdinalIgnoreCase))
            {
                lines.Add("当前状态：会只打开 Dashboard，不弹聊天窗口。");
            }
            else if (string.Equals(option.Key, "switch-model", StringComparison.OrdinalIgnoreCase))
            {
                lines.Add("当前状态：会先打开本地模型切换脚本，完成后再继续启动。");
            }
            else if (string.Equals(option.Key, "verify", StringComparison.OrdinalIgnoreCase))
            {
                lines.Add("当前状态：只做自检，不会进入主界面。");
            }
            else if (string.Equals(option.Key, "codex-login", StringComparison.OrdinalIgnoreCase))
            {
                lines.Add(state.HasCodexAuth
                    ? "Codex 登录：已检测到有效授权。"
                    : "Codex 登录：未检测到有效授权，启动后会打开登录流程。");
            }
            else if (string.Equals(option.Key, "open-home", StringComparison.OrdinalIgnoreCase))
            {
                lines.Add("当前状态：会打开 home 目录，不会启动 Hermes 主程序。");
            }
            else if (string.Equals(option.Key, "open-logs", StringComparison.OrdinalIgnoreCase))
            {
                lines.Add("当前状态：会打开 logs 目录，不会启动 Hermes 主程序。");
            }
            else if (string.Equals(option.Key, "open-custom-actions", StringComparison.OrdinalIgnoreCase))
            {
                lines.Add("当前状态：会打开 launcher-actions.txt，方便你自己加菜单项。");
            }
            else if (option.IsCustom)
            {
                if (string.Equals(option.Kind, "preset", StringComparison.OrdinalIgnoreCase))
                {
                    var values = ParseLauncherValuePairs(option.Value);
                    string providerValue;
                    string modelValue;
                    string baseUrlValue;
                    values.TryGetValue("provider", out providerValue);
                    values.TryGetValue("model", out modelValue);
                    values.TryGetValue("baseUrl", out baseUrlValue);
                    if (string.IsNullOrWhiteSpace(baseUrlValue))
                    {
                        values.TryGetValue("base_url", out baseUrlValue);
                    }

                    lines.Add(string.Format("自定义 provider: {0}", string.IsNullOrWhiteSpace(providerValue) ? "(空)" : providerValue));
                    lines.Add(string.Format("自定义 model: {0}", string.IsNullOrWhiteSpace(modelValue) ? "(空)" : modelValue));
                    lines.Add(string.Format("自定义 base_url: {0}", string.IsNullOrWhiteSpace(baseUrlValue) ? "(空)" : baseUrlValue));
                    if (string.Equals(providerValue, "openai-codex", StringComparison.OrdinalIgnoreCase))
                    {
                        lines.Add(state.HasCodexAuth
                            ? "Codex 登录：已就绪，启动后会直接继续。"
                            : "Codex 登录：未就绪，启动后会先走登录流程。");
                    }
                }
                else if (string.Equals(option.Kind, "script", StringComparison.OrdinalIgnoreCase))
                {
                    lines.Add("当前状态：会直接执行脚本，脚本结束后才会返回。");
                }
                else if (string.Equals(option.Kind, "folder", StringComparison.OrdinalIgnoreCase))
                {
                    lines.Add("当前状态：会直接打开目录。");
                }
                else if (string.Equals(option.Kind, "url", StringComparison.OrdinalIgnoreCase))
                {
                    lines.Add("当前状态：会直接打开浏览器链接。");
                }
            }

            return lines;
        }

        private static Image LoadLauncherLogoImage()
        {
            try
            {
                var logoPath = Path.Combine(Path.GetDirectoryName(Application.ExecutablePath) ?? string.Empty, "HermesGo-logo.png");
                if (File.Exists(logoPath))
                {
                    using (var stream = File.OpenRead(logoPath))
                    using (var image = Image.FromStream(stream))
                    {
                        return new Bitmap(image);
                    }
                }
            }
            catch
            {
                // Fall through to the executable icon when the dedicated logo cannot be loaded.
            }

            try
            {
                var appIcon = Icon.ExtractAssociatedIcon(Application.ExecutablePath);
                return appIcon != null ? appIcon.ToBitmap() : null;
            }
            catch
            {
                return null;
            }
        }

        private Panel CreateActionCard(string title, string description, string buttonText, EventHandler clickHandler, Color accent)
        {
            var card = new Panel
            {
                Width = 560,
                Height = 124,
                BackColor = Color.White,
                Margin = new Padding(0, 0, 0, 14),
                Padding = new Padding(16),
            };

            var accentBar = new Panel
            {
                Dock = DockStyle.Left,
                Width = 6,
                BackColor = accent,
            };

            var titleLabel = new Label
            {
                AutoSize = false,
                Left = 24,
                Top = 16,
                Width = 500,
                Height = 28,
                Font = new Font(Font.FontFamily, 13F, FontStyle.Bold),
                ForeColor = Color.FromArgb(35, 35, 40),
                Text = title,
            };

            var descriptionLabel = new Label
            {
                AutoSize = false,
                Left = 24,
                Top = 48,
                Width = 500,
                Height = 32,
                ForeColor = Color.FromArgb(90, 90, 100),
                Text = description,
            };

            var actionButton = new Button
            {
                Text = buttonText,
                Left = 24,
                Top = 82,
                Width = 180,
                Height = 30,
                FlatStyle = FlatStyle.Flat,
                BackColor = accent,
                ForeColor = Color.White,
                UseVisualStyleBackColor = false,
            };
            actionButton.FlatAppearance.BorderSize = 0;
            actionButton.Click += clickHandler;

            card.Controls.Add(actionButton);
            card.Controls.Add(descriptionLabel);
            card.Controls.Add(titleLabel);
            card.Controls.Add(accentBar);
            return card;
        }

        private void OnBeginnerRequested()
        {
            var handler = BeginnerRequested;
            if (handler != null)
            {
                handler(this, EventArgs.Empty);
            }
        }

        private void OnCloudRequested()
        {
            var handler = CloudRequested;
            if (handler != null)
            {
                handler(this, EventArgs.Empty);
            }
        }

        private void OnExpertRequested()
        {
            var handler = ExpertRequested;
            if (handler != null)
            {
                handler(this, EventArgs.Empty);
            }
        }

        private void OnSwitchModelRequested()
        {
            var handler = SwitchModelRequested;
            if (handler != null)
            {
                handler(this, EventArgs.Empty);
            }
        }

        private void OnVerifyRequested()
        {
            var handler = VerifyRequested;
            if (handler != null)
            {
                handler(this, EventArgs.Empty);
            }
        }

        private void OnCodexLoginRequested()
        {
            var handler = CodexLoginRequested;
            if (handler != null)
            {
                handler(this, EventArgs.Empty);
            }
        }

        private void OnOpenHomeRequested()
        {
            var handler = OpenHomeRequested;
            if (handler != null)
            {
                handler(this, EventArgs.Empty);
            }
        }

        private void OnOpenLogsRequested()
        {
            var handler = OpenLogsRequested;
            if (handler != null)
            {
                handler(this, EventArgs.Empty);
            }
        }

        private void OnOpenCustomActionsRequested()
        {
            var handler = OpenCustomActionsRequested;
            if (handler != null)
            {
                handler(this, EventArgs.Empty);
            }
        }

        private void OnCustomActionRequested(LauncherOption option)
        {
            var handler = CustomActionRequested;
            if (handler != null)
            {
                handler(this, option);
            }
        }

        private void OnExitRequested()
        {
            var handler = ExitRequested;
            if (handler != null)
            {
                handler(this, EventArgs.Empty);
            }
        }
    }

    private static string SanitizeFileName(string value)
    {
        if (string.IsNullOrEmpty(value))
        {
            return "source";
        }

        var invalid = Path.GetInvalidFileNameChars();
        var builder = new StringBuilder(value.Length);
        foreach (var ch in value)
        {
            if (invalid.Contains(ch))
            {
                builder.Append('_');
            }
            else
            {
                builder.Append(ch);
            }
        }

        var sanitized = builder.ToString().Trim();
        return sanitized.Length == 0 ? "source" : sanitized;
    }

    private void CleanupTempArtifacts()
    {
        try
        {
            if (Directory.Exists(_tmpRoot))
            {
                foreach (var dir in Directory.GetDirectories(_tmpRoot))
                {
                    SafeDeleteDirectory(dir);
                }

                foreach (var file in Directory.GetFiles(_tmpRoot, "*.part", SearchOption.AllDirectories))
                {
                    TryDeleteFile(file);
                }

                SafeDeleteDirectory(_tmpRoot);
            }

            foreach (var file in Directory.GetFiles(_root, "*.part", SearchOption.AllDirectories))
            {
                TryDeleteFile(file);
            }
        }
        catch (Exception ex)
        {
            Log("cleanup warning: " + ex.Message);
        }
    }

    private static void SafeDeleteDirectory(string path)
    {
        try
        {
            if (Directory.Exists(path))
            {
                Directory.Delete(path, recursive: true);
            }
        }
        catch
        {
            // Ignore cleanup failures.
        }
    }

    private static void TryDeleteFile(string path)
    {
        try
        {
            if (File.Exists(path))
            {
                File.Delete(path);
            }
        }
        catch
        {
            // Ignore cleanup failures.
        }
    }

    private static bool ReadBoolEnv(string name, bool defaultValue)
    {
        var value = Environment.GetEnvironmentVariable(name);
        if (string.IsNullOrWhiteSpace(value))
        {
            return defaultValue;
        }

        return value.Trim().Equals("1", StringComparison.OrdinalIgnoreCase) ||
               value.Trim().Equals("true", StringComparison.OrdinalIgnoreCase) ||
               value.Trim().Equals("yes", StringComparison.OrdinalIgnoreCase) ||
               value.Trim().Equals("on", StringComparison.OrdinalIgnoreCase);
    }

    private static int ReadIntEnv(string name, int defaultValue)
    {
        var value = Environment.GetEnvironmentVariable(name);
        int parsed;
        return int.TryParse(value, out parsed) ? parsed : defaultValue;
    }

    private static string StripVersionPrefix(string value)
    {
        return value.StartsWith("v", StringComparison.OrdinalIgnoreCase) ? value.Substring(1) : value;
    }

    private static bool IsLanUri(Uri uri)
    {
        if (uri == null)
        {
            return false;
        }

        if (uri.IsFile || uri.IsLoopback)
        {
            return true;
        }

        var host = uri.Host ?? string.Empty;
        if (host.Equals("localhost", StringComparison.OrdinalIgnoreCase))
        {
            return true;
        }

        IPAddress address;
        if (!IPAddress.TryParse(host, out address))
        {
            return false;
        }

        if (IPAddress.IsLoopback(address))
        {
            return true;
        }

        var bytes = address.GetAddressBytes();
        if (bytes.Length == 4)
        {
            if (bytes[0] == 10)
            {
                return true;
            }

            if (bytes[0] == 172 && bytes[1] >= 16 && bytes[1] <= 31)
            {
                return true;
            }

            if (bytes[0] == 192 && bytes[1] == 168)
            {
                return true;
            }

            if (bytes[0] == 169 && bytes[1] == 254)
            {
                return true;
            }
        }

        return false;
    }

    private void Log(string message)
    {
        try
        {
            var line = string.Format("[{0:yyyy-MM-dd HH:mm:ss}] {1}{2}", DateTime.Now, message, Environment.NewLine);
            File.AppendAllText(_logPath, line, Encoding.UTF8);
        }
        catch
        {
            // Ignore logging failures.
        }
    }

    private void RecordSourceHistory(SourceProbe probe)
    {
        try
        {
            var line = string.Format(
                "[{0:yyyy-MM-dd HH:mm:ss}] source={1} uri={2} reachable={3} local={4} range={5} len={6} sample={7} elapsedMs={8} score={9:0.00} status={10} note={11}{12}",
                DateTime.Now,
                probe.Source.Label,
                probe.Source.Raw,
                probe.Reachable,
                probe.IsLocal,
                probe.SupportsRange,
                probe.ContentLength,
                probe.SampleBytes,
                probe.Elapsed.TotalMilliseconds,
                probe.Score,
                probe.StatusCode,
                probe.Note,
                Environment.NewLine);

            File.AppendAllText(_historyPath, line, Encoding.UTF8);
        }
        catch
        {
            // Ignore history logging failures.
        }
    }

    private sealed class SourceProbe
    {
        private readonly UpdateSource _source;
        private readonly bool _reachable;
        private readonly bool _supportsRange;
        private readonly bool _isLocal;
        private readonly long _contentLength;
        private readonly long _sampleBytes;
        private readonly int _statusCode;
        private readonly string _note;
        private TimeSpan _elapsed;
        private double _score;
        private int _successfulChunks;

        private SourceProbe(UpdateSource source, bool reachable, bool supportsRange, bool isLocal, long contentLength, long sampleBytes, TimeSpan elapsed, double score, int statusCode, string note)
        {
            _source = source;
            _reachable = reachable;
            _supportsRange = supportsRange;
            _isLocal = isLocal;
            _contentLength = contentLength;
            _sampleBytes = sampleBytes;
            _elapsed = elapsed;
            _score = score;
            _statusCode = statusCode;
            _note = note;
        }

        public UpdateSource Source { get { return _source; } }
        public bool Reachable { get { return _reachable; } }
        public bool SupportsRange { get { return _supportsRange; } }
        public bool IsLocal { get { return _isLocal; } }
        public long ContentLength { get { return _contentLength; } }
        public long SampleBytes { get { return _sampleBytes; } }
        public TimeSpan Elapsed { get { return _elapsed; } }
        public double Score { get { return _score; } }
        public int StatusCode { get { return _statusCode; } }
        public string Note { get { return _note; } }
        public bool CanChunk { get { return _reachable && _contentLength > 0 && (_isLocal || _supportsRange); } }

        public static SourceProbe Local(UpdateSource source, long contentLength)
        {
            return new SourceProbe(source, true, true, true, contentLength, 0, TimeSpan.Zero, 1000000000000.0, 200, "local");
        }

        public static SourceProbe Probed(UpdateSource source, bool supportsRange, long contentLength, long sampleBytes, TimeSpan elapsed, int statusCode)
        {
            var seconds = Math.Max(elapsed.TotalSeconds, 0.001);
            var score = sampleBytes / seconds;
            return new SourceProbe(source, true, supportsRange, IsLanUri(source.Uri), contentLength, sampleBytes, elapsed, score, statusCode, "probe");
        }

        public static SourceProbe Failed(UpdateSource source, string note)
        {
            return new SourceProbe(source, false, false, IsLanUri(source.Uri), 0, 0, TimeSpan.Zero, 0, 0, note);
        }

        public void RecordChunk(long bytes, TimeSpan elapsed)
        {
            var seconds = Math.Max(elapsed.TotalSeconds, 0.001);
            var chunkScore = bytes / seconds;
            if (_successfulChunks == 0)
            {
                _score = chunkScore;
            }
            else
            {
                _score = (_score * 0.7) + (chunkScore * 0.3);
            }

            _elapsed = elapsed;
            _successfulChunks++;
        }

        public void RecordFailure()
        {
            _score *= 0.5;
            if (_score < 0)
            {
                _score = 0;
            }
        }
    }

    private sealed class ChunkDownloadResult
    {
        private readonly bool _success;
        private readonly SourceProbe _probe;
        private readonly int _bytes;
        private readonly TimeSpan _elapsed;

        private ChunkDownloadResult(bool success, SourceProbe probe, int bytes, TimeSpan elapsed)
        {
            _success = success;
            _probe = probe;
            _bytes = bytes;
            _elapsed = elapsed;
        }

        public bool Success { get { return _success; } }
        public SourceProbe Probe { get { return _probe; } }
        public int Bytes { get { return _bytes; } }
        public TimeSpan Elapsed { get { return _elapsed; } }

        public static ChunkDownloadResult Successful(SourceProbe probe, int bytes, TimeSpan elapsed)
        {
            return new ChunkDownloadResult(true, probe, bytes, elapsed);
        }

        public static ChunkDownloadResult Failed()
        {
            return new ChunkDownloadResult(false, null, 0, TimeSpan.Zero);
        }
    }

    private sealed class UpdateSource
    {
        private readonly string _raw;
        private readonly string _label;
        private readonly Uri _uri;

        public UpdateSource(string raw, string label)
        {
            _raw = raw;
            _label = label;
            _uri = BuildUri(raw);
        }

        public string Raw { get { return _raw; } }
        public string Label { get { return _label; } }
        public Uri Uri { get { return _uri; } }

        private static Uri BuildUri(string raw)
        {
            Uri uri;
            if (Uri.TryCreate(raw, UriKind.Absolute, out uri))
            {
                return uri;
            }

            var full = Path.GetFullPath(raw);
            return new Uri(full);
        }
    }

    private sealed class DownloadResult
    {
        private readonly string _sourceLabel;
        private readonly string _zipPath;
        private readonly string _md5;
        private readonly long _bytes;
        private readonly bool _success;

        public DownloadResult(string sourceLabel, string zipPath, string md5, long bytes, bool success)
        {
            _sourceLabel = sourceLabel;
            _zipPath = zipPath;
            _md5 = md5;
            _bytes = bytes;
            _success = success;
        }

        public string SourceLabel { get { return _sourceLabel; } }
        public string ZipPath { get { return _zipPath; } }
        public string Md5 { get { return _md5; } }
        public long Bytes { get { return _bytes; } }
        public bool Success { get { return _success; } }
    }

    private sealed class DownloadConsensus
    {
        private readonly string _tempRoot;
        private readonly string _zipPath;
        private readonly string _sourceLabel;
        private readonly string _md5;
        private readonly long _bytes;

        public DownloadConsensus(string tempRoot, string zipPath, string sourceLabel, string md5, long bytes)
        {
            _tempRoot = tempRoot;
            _zipPath = zipPath;
            _sourceLabel = sourceLabel;
            _md5 = md5;
            _bytes = bytes;
        }

        public string TempRoot { get { return _tempRoot; } }
        public string ZipPath { get { return _zipPath; } }
        public string SourceLabel { get { return _sourceLabel; } }
        public string Md5 { get { return _md5; } }
        public long Bytes { get { return _bytes; } }
    }
}
