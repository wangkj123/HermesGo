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

internal static class Program
{
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
    private const string Repo = "NousResearch/hermes-agent";
    private const string AssetName = "HermesGo.zip";
    private const string LocalVersionOverrideEnv = "HERMESGO_LOCAL_VERSION_OVERRIDE";
    private const string ForceUpdateEnv = "HERMESGO_FORCE_UPDATE";
    private const string SkipUpdateEnv = "HERMESGO_SKIP_UPDATE";
    private const string UpdateVersionEnv = "HERMESGO_UPDATE_VERSION";
    private const string UpdateSourcesEnv = "HERMESGO_UPDATE_SOURCES";
    private const string UpdateTimeoutEnv = "HERMESGO_UPDATE_TIMEOUT_SEC";
    private const string UseProxyEnv = "HERMESGO_UPDATE_USE_PROXY";
    private const int ProbeSampleBytes = 512 * 1024;
    private const int ChunkSizeBytes = 512 * 1024;

    private readonly string _root;
    private readonly string[] _args;
    private readonly string _logPath;
    private readonly string _tmpRoot;
    private readonly string _historyPath;

    public HermesBootstrap(string root, string[] args)
    {
        _root = root.TrimEnd(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar);
        _args = args ?? new string[0];
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
            LaunchPackage();
            return;
        }

        var localVersion = GetLocalVersion();
        var targetVersion = await ResolveTargetVersionAsync().ConfigureAwait(false);
        if (targetVersion == null)
        {
            Log("target version unavailable; launching package without update");
            LaunchPackage();
            return;
        }

        if (!ShouldUpdate(localVersion, targetVersion))
        {
            Log("package already at " + localVersion + "; launching without update");
            LaunchPackage();
            return;
        }

        Log("update needed: local=" + localVersion + ", target=" + targetVersion);

        var sources = BuildSources(targetVersion);
        if (sources.Count == 0)
        {
            Log("no update sources configured; launching package without update");
            LaunchPackage();
            return;
        }

        if (!ContainsFileSource(sources) && ContainsHttpSources(sources))
        {
            if (!await HasNetworkAsync(sources).ConfigureAwait(false))
            {
                Log("network probe failed; launching package without update");
                LaunchPackage();
                return;
            }
        }

        var result = await DownloadConsensusAsync(sources, targetVersion).ConfigureAwait(false);
        if (result == null)
        {
            Log("no valid update package found; launching package without update");
            LaunchPackage();
            return;
        }

        var extractedRoot = ExtractPackage(result.ZipPath, targetVersion);
        if (extractedRoot == null)
        {
            Log("downloaded package failed validation; launching package without update");
            LaunchPackage();
            return;
        }

        ApplyUpdate(extractedRoot);
        CleanupTempArtifacts();
        Log("update applied from " + result.SourceLabel + " (" + result.Md5 + ")");

        LaunchPackage();
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

    private void LaunchPackage()
    {
        var script = Path.Combine(_root, "Start-HermesGo.ps1");
        var batch = Path.Combine(_root, "HermesGo.bat");
        var useScript = File.Exists(script);
        var fileName = useScript ? "powershell.exe" : "cmd.exe";
        var arguments = useScript
            ? BuildPowerShellArguments(script, _args)
            : BuildBatchArguments(batch, _args);

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
