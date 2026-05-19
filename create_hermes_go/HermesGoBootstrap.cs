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
            ConfigureTransportSecurity();
            var bootstrap = new HermesBootstrap(AppContext.BaseDirectory, args);
            bootstrap.RunAsync().GetAwaiter().GetResult();
            return 0;
        }
        catch (Exception ex)
        {
            try
            {
                var bootstrapLogRoot = Directory.Exists(Path.Combine(AppContext.BaseDirectory, "app"))
                    ? Path.Combine(AppContext.BaseDirectory, "app", "logs", "update")
                    : Path.Combine(AppContext.BaseDirectory, "logs", "update");
                Directory.CreateDirectory(bootstrapLogRoot);
                File.AppendAllText(
                    Path.Combine(bootstrapLogRoot, "HermesGo-bootstrap.log"),
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

    private static void ConfigureTransportSecurity()
    {
        try
        {
            var tls12 = (SecurityProtocolType)3072;
            ServicePointManager.SecurityProtocol = SecurityProtocolType.Tls | SecurityProtocolType.Tls11 | tls12;
        }
        catch
        {
            // Keep startup working even if the runtime does not expose every protocol flag.
        }
    }
}

internal sealed class HermesBootstrap
{
    private const int SwRestore = 9;
    private const string Repo = "wangkj123/HermesGo";
    private const string AssetName = "HermesGo-green-3ui-slim.zip";
    private const string AutoUpdateEnv = "HERMESGO_AUTO_UPDATE";
    private const string AutoUpdatePromptEnv = "HERMESGO_AUTO_UPDATE_PROMPT";
    private const string AutoUpdateSilentEnv = "HERMESGO_AUTO_UPDATE_SILENT";
    private const string LocalVersionOverrideEnv = "HERMESGO_LOCAL_VERSION_OVERRIDE";
    private const string LocalReleaseTagOverrideEnv = "HERMESGO_LOCAL_RELEASE_TAG_OVERRIDE";
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
    private readonly string _contentRoot;
    private readonly string _scriptsDir;
    private readonly string _toolsDir;
    private readonly string[] _args;
    private readonly string _pythonExe;
    private readonly string _runtimeDir;
    private readonly string _runtimeBinDir;
    private readonly string _homeDir;
    private readonly string _ollamaModelsDir;
    private readonly string _logPath;
    private readonly string _tmpRoot;
    private readonly string _historyPath;
    private readonly bool _planOnly;
    private readonly bool _backgroundMaintenance;
    private readonly bool _applyUpdateNow;
    private readonly bool _showMenu;
    private readonly List<CommandPlanEntry> _planEntries = new List<CommandPlanEntry>();
    private readonly HashSet<int> _launchedProcessIds = new HashSet<int>();
    private readonly object _launchedProcessLock = new object();
    private bool _shutdownRequested;
    private bool _githubReleasesReachable;

    public HermesBootstrap(string root, string[] args)
    {
        var rawArgs = args ?? new string[0];
        _root = root.TrimEnd(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar);
        _contentRoot = ResolvePackageContentRoot(_root);
        _scriptsDir = Path.Combine(_contentRoot, "scripts");
        _toolsDir = Path.Combine(_contentRoot, "tools");
        _planOnly = HasPlanOnlyFlag(rawArgs) ||
            ReadBoolEnv("HERMESGO_DRY_RUN", defaultValue: false) ||
            ReadBoolEnv("HERMESGO_PLAN_ONLY", defaultValue: false) ||
            ReadBoolEnv("HERMESGO_DEBUG_PLAN", defaultValue: false);
        _backgroundMaintenance = HasBackgroundMaintenanceFlag(rawArgs);
        _applyUpdateNow = HasApplyUpdateNowFlag(rawArgs);
        _showMenu = HasMenuFlag(rawArgs);
        _args = rawArgs
            .Where(arg => !IsPlanOnlyFlag(arg) && !IsBackgroundMaintenanceFlag(arg) && !IsApplyUpdateNowFlag(arg) && !IsMenuFlag(arg))
            .ToArray();
        _pythonExe = Path.Combine(_contentRoot, "runtime", "python311", "python.exe");
        _runtimeDir = Path.Combine(_contentRoot, "runtime", "hermes-agent");
        _runtimeBinDir = Path.Combine(_contentRoot, "runtime", "bin");
        _homeDir = Path.Combine(_contentRoot, "home");
        _ollamaModelsDir = Path.Combine(_contentRoot, "data", "ollama", "models");
        _logPath = Path.Combine(_contentRoot, "logs", "update", "HermesGo-bootstrap.log");
        _tmpRoot = Path.Combine(Path.GetTempPath(), "hg");
        _historyPath = Path.Combine(_contentRoot, "logs", "update", "HermesGo-source-history.log");
    }

    private static bool HasPlanOnlyFlag(IEnumerable<string> args)
    {
        return args != null && args.Any(IsPlanOnlyFlag);
    }

    private static bool IsPlanOnlyFlag(string arg)
    {
        return string.Equals(arg, "--dry-run", StringComparison.OrdinalIgnoreCase) ||
               string.Equals(arg, "--plan-only", StringComparison.OrdinalIgnoreCase) ||
               string.Equals(arg, "--debug-plan", StringComparison.OrdinalIgnoreCase);
    }

    private static bool HasBackgroundMaintenanceFlag(IEnumerable<string> args)
    {
        return args != null && args.Any(IsBackgroundMaintenanceFlag);
    }

    private static bool IsBackgroundMaintenanceFlag(string arg)
    {
        return string.Equals(arg, "--background-maintenance", StringComparison.OrdinalIgnoreCase);
    }

    private static bool HasApplyUpdateNowFlag(IEnumerable<string> args)
    {
        return args != null && args.Any(IsApplyUpdateNowFlag);
    }

    private static bool IsApplyUpdateNowFlag(string arg)
    {
        return string.Equals(arg, "--apply-update-now", StringComparison.OrdinalIgnoreCase) ||
               string.Equals(arg, "--self-update-now", StringComparison.OrdinalIgnoreCase);
    }

    private static bool HasMenuFlag(IEnumerable<string> args)
    {
        return args != null && args.Any(IsMenuFlag);
    }

    private static bool IsMenuFlag(string arg)
    {
        return string.Equals(arg, "--menu", StringComparison.OrdinalIgnoreCase) ||
            string.Equals(arg, "/menu", StringComparison.OrdinalIgnoreCase);
    }

    private static string ResolvePackageContentRoot(string packageRoot)
    {
        var appRoot = Path.Combine(packageRoot, "app");
        return Directory.Exists(appRoot) ? appRoot : packageRoot;
    }

    public async Task RunAsync()
    {
        EnsureDirectories();

        if (_backgroundMaintenance)
        {
            await RunBackgroundMaintenanceAsync().ConfigureAwait(false);
            return;
        }

        if (_applyUpdateNow)
        {
            await RunApplyUpdateNowAsync().ConfigureAwait(false);
            return;
        }

        if (ShouldUseDirectLaunch())
        {
            await TryAutoUpdateBeforeLaunchAsync().ConfigureAwait(false);
            LaunchPackage(_args);
            return;
        }

        LaunchEntryPoint();
    }

    private bool ShouldUseDirectLaunch()
    {
        if (ShouldSkipLauncher())
        {
            return true;
        }

        if (_showMenu)
        {
            return false;
        }

        return true;
    }

    private async Task TryAutoUpdateBeforeLaunchAsync()
    {
        if (IsSkipped() || !ReadBoolEnv(AutoUpdateEnv, defaultValue: true))
        {
            return;
        }

        try
        {
            var localTag = GetLocalReleaseTag();
            var release = await ResolveTargetReleaseAsync().ConfigureAwait(false);
            if (release == null || !ShouldUpdateRelease(localTag, release))
            {
                return;
            }

            var targetText = release.AgentVersion != null
                ? release.AgentVersion.ToString()
                : (!string.IsNullOrWhiteSpace(release.DisplayName) ? release.DisplayName : release.TagName);

            if (ReadBoolEnv(AutoUpdateSilentEnv, defaultValue: false) || !Environment.UserInteractive)
            {
                Log("auto update before launch (silent)");
                var silentResult = await ApplyReleaseUpdateAsync(release).ConfigureAwait(false);
                if (!silentResult.Success)
                {
                    Log("auto update before launch failed: " + silentResult.Message);
                }

                return;
            }

            if (ReadBoolEnv(AutoUpdatePromptEnv, defaultValue: true))
            {
                var prompt = string.Format(
                    CultureInfo.InvariantCulture,
                    "发现 HermesGo 新版本：{0}{1}{1}是否现在下载并覆盖程序文件？{1}会保留 home、data、logs 目录。{1}{1}选择“稍后”将直接启动当前版本。",
                    targetText,
                    Environment.NewLine);
                if (!ShowPrimaryDeferPrompt("HermesGo 自动更新", prompt, "立即更新", "稍后"))
                {
                    return;
                }
            }

            Log("auto update before launch (interactive)");
            var result = await ApplyReleaseUpdateAsync(release).ConfigureAwait(false);
            if (!result.Success)
            {
                Log("auto update before launch failed: " + result.Message);
                if (Environment.UserInteractive)
                {
                    MessageBox.Show(
                        result.Message,
                        "HermesGo 自动更新失败",
                        MessageBoxButtons.OK,
                        MessageBoxIcon.Warning);
                }
            }
        }
        catch (Exception ex)
        {
            Log("auto update before launch exception: " + ex.Message);
        }
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

        var versionFile = Path.Combine(_runtimeDir, "hermes_cli", "__init__.py");
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

    private string GetLocalReleaseTag()
    {
        var overrideValue = Environment.GetEnvironmentVariable(LocalReleaseTagOverrideEnv);
        if (!string.IsNullOrWhiteSpace(overrideValue))
        {
            Log("local release tag override: " + overrideValue.Trim());
            return overrideValue.Trim();
        }

        var candidates = new[]
        {
            Path.Combine(_root, "README.txt"),
            Path.Combine(_root, "README.md"),
            Path.Combine(_contentRoot, "docs", "README.md"),
        };

        foreach (var candidate in candidates)
        {
            try
            {
                if (!File.Exists(candidate))
                {
                    continue;
                }

                var content = File.ReadAllText(candidate, Encoding.UTF8);
                var match = Regex.Match(content, @"Current release tag:\s*`?(?<tag>[^\r\n`]+)`?", RegexOptions.IgnoreCase);
                if (match.Success)
                {
                    return match.Groups["tag"].Value.Trim();
                }
            }
            catch
            {
                // Try the next local metadata file.
            }
        }

        return string.Empty;
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

    private bool ShouldPromptBeforeUpdate()
    {
        return _args.Length == 0 &&
               Environment.UserInteractive &&
               !ShouldSkipLauncher() &&
               !ReadBoolEnv(ForceUpdateEnv, defaultValue: false);
    }

    private bool PromptForUpdate(Version localVersion, Version targetVersion)
    {
        var currentText = localVersion != null ? localVersion.ToString() : "unknown";
        var latestText = targetVersion != null ? targetVersion.ToString() : "unknown";
        var message = string.Format(
            "检测到 Hermes 新版本。\r\n\r\n当前版本：{0}\r\n最新版本：{1}\r\n\r\n是否现在升级并继续启动？",
            currentText,
            latestText);

        return ShowPrimaryDeferPrompt(
            "HermesGo 版本更新",
            message,
            "更新并启动",
            "推迟");
    }

    private bool PromptForCloudConfiguration(string displayName)
    {
        var nameText = string.IsNullOrWhiteSpace(displayName) ? "Cloud: GPT-5.4 Mini" : displayName;
        var message = string.Format(
            "{0} 需要先完成 OpenAI 登录配置。\r\n\r\n现在会打开浏览器登录页，登录成功后会自动回到启动流程。\r\n\r\n是否现在开始配置？",
            nameText);

        return ShowPrimaryDeferPrompt(
            "HermesGo 云端配置",
            message,
            "开始登录",
            "推迟");
    }

    private static bool ShowPrimaryDeferPrompt(string title, string message, string primaryText, string deferText)
    {
        using (var form = new Form())
        {
            form.Text = title;
            form.StartPosition = FormStartPosition.CenterScreen;
            form.FormBorderStyle = FormBorderStyle.FixedDialog;
            form.MaximizeBox = false;
            form.MinimizeBox = false;
            form.ShowInTaskbar = false;
            form.ClientSize = new Size(440, 190);
            form.Font = SystemFonts.MessageBoxFont;

            var messageLabel = new Label
            {
                AutoSize = false,
                Left = 18,
                Top = 18,
                Width = 404,
                Height = 112,
                TextAlign = ContentAlignment.MiddleLeft,
                Text = message ?? string.Empty,
            };

            var buttons = new FlowLayoutPanel
            {
                Dock = DockStyle.Bottom,
                Height = 52,
                FlowDirection = FlowDirection.RightToLeft,
                WrapContents = false,
                Padding = new Padding(0, 8, 14, 10),
            };

            var primaryButton = new Button
            {
                Text = primaryText,
                Width = 112,
                Height = 30,
                DialogResult = DialogResult.OK,
                Margin = new Padding(8, 0, 0, 0),
            };

            var deferButton = new Button
            {
                Text = deferText,
                Width = 92,
                Height = 30,
                DialogResult = DialogResult.Cancel,
                Margin = new Padding(8, 0, 0, 0),
            };

            buttons.Controls.Add(primaryButton);
            buttons.Controls.Add(deferButton);
            form.Controls.Add(messageLabel);
            form.Controls.Add(buttons);
            form.AcceptButton = primaryButton;
            form.CancelButton = deferButton;

            return form.ShowDialog() == DialogResult.OK;
        }
    }

    private async Task<List<ReleaseInfo>> ResolveTargetReleasesAsync()
    {
        var overrideValue = Environment.GetEnvironmentVariable(UpdateVersionEnv);
        if (!string.IsNullOrWhiteSpace(overrideValue))
        {
            var tag = overrideValue.Trim();
            Log("target release override: " + tag);
            var releasesFromApi = await FetchReleasesFromGitHubApiAsync().ConfigureAwait(false);
            if (releasesFromApi != null)
            {
                var matched = releasesFromApi.FirstOrDefault(
                    release => release != null &&
                               string.Equals(release.TagName, tag, StringComparison.OrdinalIgnoreCase));
                if (matched != null)
                {
                    Log("target release override matched GitHub release assets");
                    return new List<ReleaseInfo> { matched };
                }
            }

            return new List<ReleaseInfo>
            {
                new ReleaseInfo
                {
                    TagName = tag,
                    DisplayName = tag,
                    ZipAssetNames = new List<string>(),
                    ZipAssetUrls = new List<string>(),
                },
            };
        }

        string probeFailure = null;
        try
        {
            var releases = await FetchReleasesFromGitHubApiAsync().ConfigureAwait(false);
            if (releases != null)
            {
                return releases;
            }
        }
        catch (Exception ex)
        {
            probeFailure = ex.Message;
        }

        if (!string.IsNullOrWhiteSpace(probeFailure))
        {
            Log("Hermes release list probe failed: " + probeFailure);
            var atomFallback = await ResolveTargetReleasesFromAtomAsync().ConfigureAwait(false);
            if (atomFallback != null && atomFallback.Count > 0)
            {
                return atomFallback;
            }
        }

        return null;
    }

    private async Task<List<ReleaseInfo>> FetchReleasesFromGitHubApiAsync()
    {
        using (var client = CreateHttpClient())
        {
            var request = new HttpRequestMessage(HttpMethod.Get, string.Format("https://api.github.com/repos/{0}/releases?per_page=10", Repo));
            request.Headers.UserAgent.ParseAdd("HermesGoBootstrap/1.0");
            request.Headers.Accept.ParseAdd("application/vnd.github+json");
            request.Headers.TryAddWithoutValidation("X-GitHub-Api-Version", "2022-11-28");

            using (var response = await client.SendAsync(request).ConfigureAwait(false))
            {
                if (!response.IsSuccessStatusCode)
                {
                    throw new InvalidOperationException("HermesGo release list probe failed: " + response.StatusCode);
                }

                var json = await response.Content.ReadAsStringAsync().ConfigureAwait(false);
                var serializer = new JavaScriptSerializer();
                var payload = serializer.DeserializeObject(json) as object[];
                if (payload == null)
                {
                    throw new InvalidOperationException("HermesGo release list payload was not an array");
                }

                var releases = new List<ReleaseInfo>();
                foreach (var item in payload)
                {
                    var releasePayload = item as Dictionary<string, object>;
                    if (releasePayload == null || !releasePayload.ContainsKey("tag_name"))
                    {
                        continue;
                    }

                    bool isDraft = releasePayload.ContainsKey("draft") && Convert.ToBoolean(releasePayload["draft"], CultureInfo.InvariantCulture);
                    bool isPrerelease = releasePayload.ContainsKey("prerelease") && Convert.ToBoolean(releasePayload["prerelease"], CultureInfo.InvariantCulture);
                    if (isDraft || isPrerelease)
                    {
                        continue;
                    }

                    var release = new ReleaseInfo
                    {
                        TagName = Convert.ToString(releasePayload["tag_name"], CultureInfo.InvariantCulture),
                        DisplayName = releasePayload.ContainsKey("name") ? Convert.ToString(releasePayload["name"], CultureInfo.InvariantCulture) : string.Empty,
                        Body = releasePayload.ContainsKey("body") ? Convert.ToString(releasePayload["body"], CultureInfo.InvariantCulture) : string.Empty,
                        SourceZipUrl = releasePayload.ContainsKey("zipball_url") ? Convert.ToString(releasePayload["zipball_url"], CultureInfo.InvariantCulture) : string.Empty,
                        ZipAssetNames = new List<string>(),
                        ZipAssetUrls = new List<string>(),
                    };
                    release.AgentVersion = ParseAgentVersion(release.DisplayName, release.Body, release.TagName);

                    object assetsValue;
                    if (releasePayload.TryGetValue("assets", out assetsValue))
                    {
                        var assets = assetsValue as object[];
                        if (assets != null)
                        {
                            foreach (var assetValue in assets)
                            {
                                var asset = assetValue as Dictionary<string, object>;
                                if (asset == null)
                                {
                                    continue;
                                }

                                var name = asset.ContainsKey("name") ? Convert.ToString(asset["name"], CultureInfo.InvariantCulture) : string.Empty;
                                var url = asset.ContainsKey("browser_download_url") ? Convert.ToString(asset["browser_download_url"], CultureInfo.InvariantCulture) : string.Empty;
                                if (string.IsNullOrWhiteSpace(name) || !name.EndsWith(".zip", StringComparison.OrdinalIgnoreCase))
                                {
                                    continue;
                                }

                                release.ZipAssetNames.Add(name);
                                if (!string.IsNullOrWhiteSpace(url))
                                {
                                    release.ZipAssetUrls.Add(url);
                                }
                            }
                        }
                    }

                    releases.Add(release);
                }

                NormalizeAndSortReleases(releases);
                _githubReleasesReachable = releases.Count > 0;
                Log("Hermes release list from GitHub: " + releases.Count);
                return releases;
            }
        }
    }

    private async Task<List<ReleaseInfo>> ResolveTargetReleasesFromAtomAsync()
    {
        try
        {
            using (var client = CreateHttpClient())
            {
                var request = new HttpRequestMessage(HttpMethod.Get, string.Format("https://github.com/{0}/releases.atom", Repo));
                request.Headers.UserAgent.ParseAdd("HermesGoBootstrap/1.0");

                using (var response = await client.SendAsync(request).ConfigureAwait(false))
                {
                    if (!response.IsSuccessStatusCode)
                    {
                        Log("Hermes release atom probe failed: " + response.StatusCode);
                        return null;
                    }

                    var xml = await response.Content.ReadAsStringAsync().ConfigureAwait(false);
                    var entries = Regex.Matches(xml, @"<entry>(?<body>.*?)</entry>", RegexOptions.Singleline | RegexOptions.IgnoreCase);
                    var releases = new List<ReleaseInfo>();
                    foreach (Match entry in entries)
                    {
                        var body = entry.Groups["body"].Value;
                        var titleMatch = Regex.Match(body, @"<title[^>]*>(?<v>.*?)</title>", RegexOptions.Singleline | RegexOptions.IgnoreCase);
                        var linkMatch = Regex.Match(body, @"<link[^>]*href=""(?<v>[^""]+)""", RegexOptions.Singleline | RegexOptions.IgnoreCase);
                        if (!titleMatch.Success || !linkMatch.Success)
                        {
                            continue;
                        }

                        var title = WebUtility.HtmlDecode(titleMatch.Groups["v"].Value).Trim();
                        var link = linkMatch.Groups["v"].Value.Trim();
                        var tagMatch = Regex.Match(link, @"/releases/tag/(?<tag>[^/?#]+)", RegexOptions.IgnoreCase);
                        var tag = tagMatch.Success ? tagMatch.Groups["tag"].Value.Trim() : string.Empty;
                        var release = new ReleaseInfo
                        {
                            TagName = tag,
                            DisplayName = title,
                            Body = string.Empty,
                            SourceZipUrl = string.IsNullOrWhiteSpace(tag)
                                ? string.Empty
                                : string.Format("https://github.com/{0}/archive/refs/tags/{1}.zip", Repo, tag),
                            ZipAssetNames = new List<string>(),
                            ZipAssetUrls = new List<string>(),
                        };
                        release.AgentVersion = ParseAgentVersion(release.DisplayName, release.Body, release.TagName);
                        releases.Add(release);
                    }

                    _githubReleasesReachable = releases.Count > 0;
                    Log("Hermes release list from GitHub Atom: " + releases.Count);
                    return releases;
                }
            }
        }
        catch (Exception ex)
        {
            Log("Hermes release atom probe failed: " + ex.Message);
            return null;
        }
    }

    private async Task<ReleaseInfo> ResolveTargetReleaseAsync()
    {
        var releases = await ResolveTargetReleasesAsync().ConfigureAwait(false);
        return releases != null && releases.Count > 0 ? releases[0] : null;
    }

    private static Version ParseAgentVersion(params string[] values)
    {
        foreach (var value in values)
        {
            if (string.IsNullOrWhiteSpace(value))
            {
                continue;
            }

            var match = Regex.Match(value, @"\bv(?<v>\d+\.\d+\.\d+)\b", RegexOptions.IgnoreCase);
            if (!match.Success)
            {
                continue;
            }

            Version version;
            if (Version.TryParse(match.Groups["v"].Value, out version))
            {
                return version;
            }
        }

        return null;
    }

    private bool ShouldUpdateRelease(string localTag, ReleaseInfo targetRelease)
    {
        if (ReadBoolEnv(ForceUpdateEnv, defaultValue: false))
        {
            Log("force update enabled");
            return true;
        }

        if (targetRelease == null)
        {
            return false;
        }

        var localVersion = GetLocalVersion();
        if (targetRelease.AgentVersion != null)
        {
            return targetRelease.AgentVersion > localVersion;
        }

        return !string.Equals(localTag ?? string.Empty, targetRelease.TagName, StringComparison.OrdinalIgnoreCase);
    }

    private async Task<UpdateResult> ApplyReleaseUpdateAsync(ReleaseInfo targetRelease, Action<string> progressReporter = null)
    {
        if (targetRelease == null)
        {
            return UpdateResult.Failed("没有可用的新发行版信息。");
        }

        var sources = BuildSources(targetRelease);
        if (sources.Count == 0)
        {
            Log("no update sources configured; update aborted");
            return UpdateResult.Failed("没有找到可下载的发行版 zip。");
        }

        if (!ContainsFileSource(sources) && ContainsHttpSources(sources))
        {
            ReportUpdateProgress(progressReporter, "正在探测更新源...");
            if (!await HasNetworkAsync(sources).ConfigureAwait(false))
            {
                Log("network probe failed; update aborted");
                return UpdateResult.Failed("网络探测失败，未开始下载。");
            }
        }

        ReportUpdateProgress(progressReporter, "正在下载并校验更新包...");
        var result = await DownloadConsensusAsync(sources, targetRelease.TagName).ConfigureAwait(false);
        if (result == null)
        {
            Log("no valid update package found; update aborted");
            return UpdateResult.Failed("没有下载到有效的发行版 zip。");
        }

        ReportUpdateProgress(progressReporter, "正在解包更新包...");
        var extractedRoot = ExtractPackage(result.ZipPath, targetRelease.TagName);
        if (extractedRoot == null)
        {
            Log("downloaded package failed validation; update aborted");
            return UpdateResult.Failed("下载的 HermesGo 便携包结构校验失败，未覆盖当前文件。");
        }

        ReportUpdateProgress(progressReporter, "正在停止 Hermes 相关进程...");
        StopPortableHermesProcessesBeforeUpdate();
        ReportUpdateProgress(progressReporter, "正在覆盖 HermesGo 便携包文件...");
        ApplyUpdate(extractedRoot);
        ReportUpdateProgress(progressReporter, "正在清理临时文件...");
        CleanupTempArtifacts();
        Log("package update applied from " + result.SourceLabel + " (" + result.Md5 + ")");
        var summaryText = "便携包已更新到 " + targetRelease.TagName + "。";
        return UpdateResult.Successful(result.SourceLabel, result.Md5, result.Bytes, summaryText);
    }

    private List<UpdateSource> BuildSources(ReleaseInfo targetRelease)
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

        var tag = targetRelease != null ? targetRelease.TagName : string.Empty;
        var assetNames = GetPreferredPackageAssetNames(targetRelease);
        var candidates = new List<UpdateSource>();

        if (ReadBoolEnv("HERMESGO_UPDATE_INCLUDE_SOURCE", defaultValue: false))
        {
            if (targetRelease != null && !string.IsNullOrWhiteSpace(targetRelease.SourceZipUrl))
            {
                candidates.Add(new UpdateSource(targetRelease.SourceZipUrl, "github-source-zipball"));
            }

            if (!string.IsNullOrWhiteSpace(tag))
            {
                candidates.Add(new UpdateSource(string.Format("https://github.com/{0}/archive/refs/tags/{1}.zip", Repo, tag), "github-source-archive"));
            }
        }

        foreach (var assetName in assetNames)
        {
            candidates.Add(new UpdateSource(string.Format("https://github.com/{0}/releases/download/{1}/{2}", Repo, tag, assetName), "github-versioned-" + assetName));
        }

        if (targetRelease != null && targetRelease.ZipAssetUrls != null)
        {
            foreach (var url in targetRelease.ZipAssetUrls)
            {
                candidates.Add(new UpdateSource(url, "github-asset-api"));
            }
        }

        AppendMirrorSources(candidates);

        Log("default update sources: " + candidates.Count);
        return candidates;
    }

    private static List<string> GetPreferredPackageAssetNames(ReleaseInfo targetRelease)
    {
        if (targetRelease == null || targetRelease.ZipAssetNames == null || targetRelease.ZipAssetNames.Count == 0)
        {
            return new List<string> { AssetName };
        }

        OrderPackageZipAssets(targetRelease);
        var preferred = targetRelease.ZipAssetNames
            .Where(name => ScorePackageAsset(name) >= 0)
            .ToList();
        return preferred.Count > 0 ? preferred : new List<string>(targetRelease.ZipAssetNames);
    }

    private static void NormalizeAndSortReleases(List<ReleaseInfo> releases)
    {
        if (releases == null || releases.Count == 0)
        {
            return;
        }

        foreach (var release in releases)
        {
            OrderPackageZipAssets(release);
        }

        releases.Sort(delegate(ReleaseInfo left, ReleaseInfo right)
        {
            var leftVersion = left != null && left.AgentVersion != null ? left.AgentVersion : new Version(0, 0, 0);
            var rightVersion = right != null && right.AgentVersion != null ? right.AgentVersion : new Version(0, 0, 0);
            return rightVersion.CompareTo(leftVersion);
        });
    }

    private static void OrderPackageZipAssets(ReleaseInfo release)
    {
        if (release == null || release.ZipAssetNames == null || release.ZipAssetNames.Count == 0)
        {
            return;
        }

        var pairs = new List<KeyValuePair<string, string>>();
        for (var index = 0; index < release.ZipAssetNames.Count; index++)
        {
            var name = release.ZipAssetNames[index];
            var url = release.ZipAssetUrls != null && index < release.ZipAssetUrls.Count
                ? release.ZipAssetUrls[index]
                : string.Empty;
            pairs.Add(new KeyValuePair<string, string>(name, url));
        }

        pairs.Sort((left, right) => ScorePackageAsset(right.Key).CompareTo(ScorePackageAsset(left.Key)));
        release.ZipAssetNames = pairs.Select(pair => pair.Key).ToList();
        release.ZipAssetUrls = pairs.Select(pair => pair.Value).Where(url => !string.IsNullOrWhiteSpace(url)).ToList();
    }

    private static int ScorePackageAsset(string name)
    {
        if (string.IsNullOrWhiteSpace(name) || !name.EndsWith(".zip", StringComparison.OrdinalIgnoreCase))
        {
            return -100;
        }

        var lower = name.ToLowerInvariant();
        var score = 0;
        if (lower.Contains("hermesgo"))
        {
            score += 10;
        }

        if (lower.Contains("green") && lower.Contains("3ui"))
        {
            score += 40;
        }
        else if (lower.Contains("3ui"))
        {
            score += 20;
        }

        if (lower.Contains("slim"))
        {
            score += 15;
        }

        if (lower.Contains("hermes-agent") || lower.Contains("source"))
        {
            score -= 60;
        }

        return score;
    }

    private static void AppendMirrorSources(List<UpdateSource> candidates)
    {
        if (candidates == null || candidates.Count == 0)
        {
            return;
        }

        var mirrorPrefixes = new[]
        {
            "https://ghfast.top/",
            "https://mirror.ghproxy.com/",
        };
        var existing = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        foreach (var source in candidates)
        {
            if (source != null && !string.IsNullOrWhiteSpace(source.Raw))
            {
                existing.Add(source.Raw);
            }
        }

        var mirrorInsertIndex = 0;
        foreach (var source in candidates.ToList())
        {
            if (source == null || string.IsNullOrWhiteSpace(source.Raw))
            {
                continue;
            }

            var raw = source.Raw.Trim();
            if (!raw.StartsWith("https://github.com/", StringComparison.OrdinalIgnoreCase))
            {
                continue;
            }

            for (var index = mirrorPrefixes.Length - 1; index >= 0; index--)
            {
                var mirrored = mirrorPrefixes[index] + raw;
                if (existing.Add(mirrored))
                {
                    candidates.Insert(
                        mirrorInsertIndex,
                        new UpdateSource(mirrored, source.Label + "-mirror" + (index + 1).ToString(CultureInfo.InvariantCulture)));
                    mirrorInsertIndex++;
                }
            }
        }
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
        if (ReadBoolEnv("HERMESGO_SKIP_NETWORK_PROBE", defaultValue: false))
        {
            Log("network probe skipped via HERMESGO_SKIP_NETWORK_PROBE");
            return true;
        }

        if (_githubReleasesReachable)
        {
            Log("network probe skipped: GitHub releases API already reachable");
            return true;
        }

        var firstHttp = sources.FirstOrDefault(s => s.Uri.Scheme == Uri.UriSchemeHttp || s.Uri.Scheme == Uri.UriSchemeHttps);
        if (firstHttp == null)
        {
            return true;
        }

        var probeTargets = new List<Uri>();
        probeTargets.Add(new Uri(string.Format("https://api.github.com/repos/{0}", Repo)));
        if (!probeTargets.Any(uri => string.Equals(uri.Host, firstHttp.Uri.Host, StringComparison.OrdinalIgnoreCase)))
        {
            probeTargets.Add(firstHttp.Uri);
        }

        var probeSeconds = ReadIntEnv("HERMESGO_NETWORK_PROBE_SEC", 12);
        foreach (var probeUri in probeTargets)
        {
            if (await ProbeNetworkEndpointAsync(probeUri, probeSeconds, useProxy: false).ConfigureAwait(false))
            {
                return true;
            }

            if (ReadBoolEnv(UseProxyEnv, defaultValue: false))
            {
                if (await ProbeNetworkEndpointAsync(probeUri, probeSeconds, useProxy: true).ConfigureAwait(false))
                {
                    return true;
                }
            }
        }

        Log("network probe failed for all targets");
        return false;
    }

    private async Task<bool> ProbeNetworkEndpointAsync(Uri probeUri, int probeSeconds, bool useProxy)
    {
        try
        {
            using (var client = CreateHttpClient(useProxy))
            {
                var method = string.Equals(probeUri.Host, "api.github.com", StringComparison.OrdinalIgnoreCase)
                    ? HttpMethod.Head
                    : HttpMethod.Get;
                using (var request = new HttpRequestMessage(method, probeUri))
                using (var cts = new CancellationTokenSource(TimeSpan.FromSeconds(Math.Max(4, probeSeconds))))
                {
                    request.Headers.UserAgent.ParseAdd("HermesGoBootstrap/1.0");
                    if (method == HttpMethod.Get)
                    {
                        request.Headers.Range = new System.Net.Http.Headers.RangeHeaderValue(0, 0);
                    }

                    using (var response = await client.SendAsync(request, HttpCompletionOption.ResponseHeadersRead, cts.Token).ConfigureAwait(false))
                    {
                        Log("network probe ok"
                            + (useProxy ? " (proxy)" : string.Empty)
                            + ": "
                            + probeUri.Host
                            + " -> "
                            + (int)response.StatusCode);
                        return response.IsSuccessStatusCode || response.StatusCode == HttpStatusCode.PartialContent;
                    }
                }
            }
        }
        catch (Exception ex)
        {
            Log("network probe failed"
                + (useProxy ? " (proxy)" : string.Empty)
                + " for "
                + probeUri.Host
                + ": "
                + ex.Message);
            return false;
        }
    }

    private HttpClient CreateHttpClient()
    {
        return CreateHttpClient(ReadBoolEnv(UseProxyEnv, defaultValue: false));
    }

    private HttpClient CreateHttpClient(bool useProxy)
    {
        var handler = new HttpClientHandler
        {
            UseProxy = useProxy,
            Proxy = useProxy ? WebRequest.GetSystemWebProxy() : null,
            AutomaticDecompression = DecompressionMethods.GZip | DecompressionMethods.Deflate,
        };

        var client = new HttpClient(handler, disposeHandler: true)
        {
            Timeout = TimeSpan.FromSeconds(ReadIntEnv(UpdateTimeoutEnv, 180))
        };
        client.DefaultRequestHeaders.UserAgent.ParseAdd("HermesGoBootstrap/1.0");
        return client;
    }

    private async Task<DownloadConsensus> DownloadConsensusAsync(IReadOnlyCollection<UpdateSource> sources, string targetReleaseTag)
    {
        Directory.CreateDirectory(_tmpRoot);
        var tempDir = Path.Combine(
            _tmpRoot,
            string.Format(
                "d-{0:yyyyMMddHHmmssfff}-{1}",
                DateTime.UtcNow,
                Guid.NewGuid().ToString("N").Substring(0, 8)));
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
                var result = await DownloadOneAsync(probe.Source, targetReleaseTag, tempDir, 0).ConfigureAwait(false);
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

    private async Task<DownloadResult> DownloadOneAsync(UpdateSource source, string targetReleaseTag, string tempDir, int index)
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

    private string ExtractPackage(string zipPath, string targetReleaseTag)
    {
        var stagingDir = Path.Combine(
            _tmpRoot,
            string.Format(
                "e-{0:yyyyMMddHHmmssfff}-{1}",
                DateTime.UtcNow,
                Guid.NewGuid().ToString("N").Substring(0, 8)));
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

            Log("staged package ready for " + targetReleaseTag);
            return root;
        }
        catch (Exception ex)
        {
            Log("package extraction failed: " + ex.Message);
            SafeDeleteDirectory(stagingDir);
            return null;
        }
    }

    private string ExtractHermesSourcePackage(string zipPath, string targetReleaseTag)
    {
        var stagingDir = Path.Combine(
            _tmpRoot,
            string.Format(
                "s-{0:yyyyMMddHHmmssfff}-{1}",
                DateTime.UtcNow,
                Guid.NewGuid().ToString("N").Substring(0, 8)));
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
            if (root == null || !ValidateHermesSourceRoot(root))
            {
                Log("extracted Hermes source root failed validation");
                SafeDeleteDirectory(stagingDir);
                return null;
            }

            Log("staged Hermes source ready for " + targetReleaseTag);
            return root;
        }
        catch (Exception ex)
        {
            Log("Hermes source extraction failed: " + ex.Message);
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
        var contentRoot = ResolvePackageContentRoot(packageRoot);
        var required = new[]
        {
            Path.Combine(contentRoot, "scripts", "Start-HermesGo.ps1"),
            Path.Combine(contentRoot, "runtime", "python311", "python.exe"),
            Path.Combine(contentRoot, "runtime", "hermes-agent", "hermes_cli", "__init__.py"),
        };

        if (!required.All(File.Exists))
        {
            return false;
        }

        return File.Exists(Path.Combine(packageRoot, "HermesGo.exe")) ||
            File.Exists(Path.Combine(contentRoot, "HermesGo.exe"));
    }

    private bool ValidateHermesSourceRoot(string sourceRoot)
    {
        var required = new[]
        {
            Path.Combine(sourceRoot, "pyproject.toml"),
            Path.Combine(sourceRoot, "run_agent.py"),
            Path.Combine(sourceRoot, "hermes_cli", "__init__.py"),
        };

        return required.All(File.Exists);
    }

    private sealed class UpdateSummary
    {
        public int CopiedFiles { get; set; }
        public int PrunedItems { get; set; }
        public List<string> SamplePaths { get; private set; }

        public UpdateSummary()
        {
            SamplePaths = new List<string>();
        }
    }

    private UpdateSummary ApplyHermesSourceUpdate(string sourceRoot)
    {
        var summary = new UpdateSummary();
        var skipDirectories = new HashSet<string>(StringComparer.OrdinalIgnoreCase)
        {
            ".git",
            ".github",
            ".venv",
            "venv",
            "node_modules",
            "web",
            "__pycache__",
        };
        var protectedPortableFiles = new HashSet<string>(StringComparer.OrdinalIgnoreCase)
        {
            "hermes_cli/auth.py",
            "hermes_cli/auth_commands.py",
            "hermes_cli/main.py",
            "hermes_cli/web_server.py",
        };

        foreach (var file in Directory.GetFiles(sourceRoot, "*", SearchOption.AllDirectories))
        {
            var relative = GetRelativePath(sourceRoot, file);
            var normalized = relative.Replace('\\', '/');
            var parts = normalized.Split(new[] { '/' }, StringSplitOptions.RemoveEmptyEntries);
            if (parts.Any(part => skipDirectories.Contains(part)))
            {
                continue;
            }

            if (protectedPortableFiles.Contains(normalized))
            {
                continue;
            }

            if (normalized.EndsWith(".pyc", StringComparison.OrdinalIgnoreCase) ||
                normalized.EndsWith(".pyo", StringComparison.OrdinalIgnoreCase))
            {
                continue;
            }

            var destination = Path.Combine(_runtimeDir, relative);
            Directory.CreateDirectory(Path.GetDirectoryName(destination) ?? _runtimeDir);
            File.Copy(file, destination, overwrite: true);
            summary.CopiedFiles++;
            if (summary.SamplePaths.Count < 10)
            {
                summary.SamplePaths.Add(normalized);
            }
        }

        summary.PrunedItems = PrunePortableRuntimeAfterSourceUpdate();
        return summary;
    }

    private int PrunePortableRuntimeAfterSourceUpdate()
    {
        var pathsToRemove = new[]
        {
            Path.Combine(_runtimeDir, "web"),
            Path.Combine(_runtimeDir, "node_modules"),
            Path.Combine(_runtimeDir, "tests"),
            Path.Combine(_runtimeDir, "scripts"),
            Path.Combine(_runtimeDir, "hermes_agent.egg-info"),
            Path.Combine(_runtimeDir, "README.md"),
            Path.Combine(_runtimeDir, "LICENSE"),
            Path.Combine(_runtimeDir, "MANIFEST.in"),
            Path.Combine(_runtimeDir, "package.json"),
            Path.Combine(_runtimeDir, "package-lock.json"),
            Path.Combine(_runtimeDir, "pyproject.toml"),
            Path.Combine(_runtimeDir, "requirements.txt"),
            Path.Combine(_runtimeDir, "uv.lock"),
            Path.Combine(_runtimeDir, ".env.example"),
            Path.Combine(_runtimeDir, "cli-config.yaml.example"),
            Path.Combine(_runtimeDir, "hermes"),
        };

        var removed = 0;
        foreach (var path in pathsToRemove)
        {
            if (Directory.Exists(path))
            {
                SafeDeleteDirectory(path);
                removed++;
            }
            else if (File.Exists(path))
            {
                TryDeleteFile(path);
                removed++;
            }
        }

        foreach (var dir in Directory.GetDirectories(_runtimeDir, "__pycache__", SearchOption.AllDirectories))
        {
            SafeDeleteDirectory(dir);
            removed++;
        }

        Log("portable runtime prune after source update: removed=" + removed.ToString(CultureInfo.InvariantCulture));
        return removed;
    }

    private void StopPortableHermesProcessesBeforeUpdate()
    {
        Log("stopping portable Hermes processes before package update");
        ShutdownLaunchedProcesses();

        var processIds = new HashSet<int>();
        foreach (var process in Process.GetProcesses())
        {
            try
            {
                var modulePath = process.MainModule != null ? process.MainModule.FileName : string.Empty;
                if (string.IsNullOrWhiteSpace(modulePath))
                {
                    continue;
                }

                if (modulePath.StartsWith(_contentRoot, StringComparison.OrdinalIgnoreCase) ||
                    modulePath.StartsWith(_root, StringComparison.OrdinalIgnoreCase))
                {
                    processIds.Add(process.Id);
                }
            }
            catch
            {
                // Access denied for some system processes; ignore.
            }
            finally
            {
                process.Dispose();
            }
        }

        foreach (var processId in processIds)
        {
            if (processId == Process.GetCurrentProcess().Id)
            {
                continue;
            }

            KillProcessTree(processId);
        }

        Thread.Sleep(1500);
    }

    private void ApplyUpdate(string extractedRoot)
    {
        var extractedContentRoot = ResolvePackageContentRoot(extractedRoot);
        var contentPrefix = GetRelativePath(extractedRoot, extractedContentRoot)
            .Replace('\\', '/')
            .Trim('/');
        var preserveRoots = new HashSet<string>(StringComparer.OrdinalIgnoreCase)
        {
            string.IsNullOrEmpty(contentPrefix) ? "home" : contentPrefix + "/home",
            string.IsNullOrEmpty(contentPrefix) ? "data" : contentPrefix + "/data",
            string.IsNullOrEmpty(contentPrefix) ? "logs" : contentPrefix + "/logs",
        };

        var lockedFiles = new List<string>();
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
            if (!TryCopyFileWithRetry(file, destination, maxAttempts: 3))
            {
                lockedFiles.Add(relative);
            }
        }

        if (lockedFiles.Count > 0)
        {
            Log("apply update skipped locked files: " + lockedFiles.Count);
            throw new IOException(
                "部分文件被占用，更新未完成。请关闭 Hermes Desktop / WebUI / Gateway 后重试。示例：" +
                lockedFiles[0]);
        }
    }

    private bool TryCopyFileWithRetry(string source, string destination, int maxAttempts)
    {
        for (var attempt = 1; attempt <= maxAttempts; attempt++)
        {
            try
            {
                File.Copy(source, destination, overwrite: true);
                return true;
            }
            catch (IOException ex)
            {
                Log("file copy retry " + attempt + "/" + maxAttempts + " failed for " + destination + ": " + ex.Message);
                if (attempt >= maxAttempts)
                {
                    return false;
                }

                StopPortableHermesProcessesBeforeUpdate();
                Thread.Sleep(1000 * attempt);
            }
        }

        return false;
    }

    private static string BuildUpdateSummaryText(UpdateSummary summary)
    {
        if (summary == null)
        {
            return "未生成更新摘要。";
        }

        var lines = new List<string>
        {
            "覆盖文件数：" + summary.CopiedFiles.ToString(CultureInfo.InvariantCulture),
            "清理项数：" + summary.PrunedItems.ToString(CultureInfo.InvariantCulture),
        };

        if (summary.SamplePaths != null && summary.SamplePaths.Count > 0)
        {
            lines.Add("示例文件：");
            foreach (var sample in summary.SamplePaths)
            {
                lines.Add("- " + sample);
            }
        }

        return string.Join(Environment.NewLine, lines.ToArray());
    }

    private void ReportUpdateProgress(Action<string> progressReporter, string message)
    {
        Log(message);
        if (progressReporter == null)
        {
            return;
        }

        try
        {
            progressReporter(message);
        }
        catch
        {
            // Best effort only.
        }
    }

    private bool ShouldSkipPath(string relativePath, HashSet<string> preserveRoots)
    {
        var normalized = relativePath.Replace('\\', '/').Trim('/');
        foreach (var preserveRoot in preserveRoots)
        {
            if (normalized.Equals(preserveRoot, StringComparison.OrdinalIgnoreCase) ||
                normalized.StartsWith(preserveRoot + "/", StringComparison.OrdinalIgnoreCase))
            {
                return true;
            }
        }

        return false;
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
            form.FullLaunchRequested += delegate
            {
                RunLauncherActionAsync(form, delegate
                {
                    LaunchPackage(new string[0]);
                    return true;
                });
            };
            form.WebUiOnlyRequested += delegate
            {
                RunLauncherActionAsync(form, delegate
                {
                    LaunchWebUiOnly();
                    return true;
                });
            };
            form.DesktopOnlyRequested += delegate
            {
                RunLauncherActionAsync(form, delegate
                {
                    LaunchDesktopOnly();
                    return true;
                });
            };
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
            form.UiSuiteLaunchRequested += delegate(object sender, LauncherForm.UiSuiteSelection selection)
            {
                RunLauncherActionAsync(form, delegate
                {
                    return HandleUiSuiteSelectionLaunch(selection);
                });
            };
            form.OpenHomeRequested += delegate
            {
                RunLauncherActionAsync(form, delegate
                {
                    OpenFolder(_homeDir);
                    return true;
                });
            };
            form.OpenLogsRequested += delegate
            {
                RunLauncherActionAsync(form, delegate
                {
                    OpenFolder(Path.Combine(_contentRoot, "logs"));
                    return true;
                });
            };
            form.OpenCustomActionsRequested += delegate
            {
                RunLauncherActionAsync(form, delegate
                {
                    OpenTextFile(Path.Combine(_homeDir, "launcher-actions.txt"));
                    return true;
                });
            };
            form.CustomActionRequested += delegate(object sender, LauncherForm.LauncherOption option)
            {
                RunLauncherActionAsync(form, delegate
                {
                    return HandleCustomLauncherAction(option);
                });
            };
            form.ExitRequested += delegate
            {
                ShutdownLaunchedProcesses();
                form.Close();
            };
            form.FormClosing += delegate
            {
                ShutdownLaunchedProcesses();
            };
            form.UpdateRequested += delegate
            {
                var release = form.PendingUpdate;
                if (release == null)
                {
                    StartBackgroundUpdateCheck(form, false);
                    return;
                }

                var currentVersion = GetLocalVersion();
                var currentVersionText = currentVersion != null ? currentVersion.ToString() : "unknown";
                var targetVersionText = release.AgentVersion != null ? release.AgentVersion.ToString() : (!string.IsNullOrWhiteSpace(release.DisplayName) ? release.DisplayName : release.TagName);
                            form.SetUpdateStatus("当前版本 " + currentVersionText + "，目标版本 " + targetVersionText + "，正在下载并覆盖 HermesGo 便携包...", false, false, release);
                RunLauncherActionAsync(form, delegate
                {
                    Action<string> progressReporter = delegate(string message)
                    {
                        if (!form.IsHandleCreated)
                        {
                            return;
                        }

                        try
                        {
                            form.BeginInvoke(new Action(delegate
                            {
                                form.SetUpdateStatus(message, false, false, release);
                            }));
                        }
                        catch
                        {
                            // Best effort only.
                        }
                    };

                    var updateResult = ApplyReleaseUpdateAsync(release, progressReporter).GetAwaiter().GetResult();
                    form.BeginInvoke(new Action(delegate
                    {
                        if (updateResult.Success)
                        {
                            var summaryText = string.IsNullOrWhiteSpace(updateResult.Summary) ? "未生成更新摘要。" : updateResult.Summary;
                            form.SetUpdateStatus("当前版本 " + targetVersionText + "，更新完成。请关闭后重新打开 HermesGo.exe 使用新版。", true, false, release);
                            MessageBox.Show(
                                form,
                                "当前版本：" + currentVersionText + "\r\n目标版本：" + targetVersionText + "\r\n\r\nHermesGo 便携包已覆盖更新。\r\n\r\n来源：" + updateResult.SourceLabel + "\r\nMD5：" + updateResult.Md5 + "\r\n\r\n更新摘要：\r\n" + summaryText + "\r\n\r\n请重新打开 HermesGo.exe。",
                                "HermesGo 更新完成",
                                MessageBoxButtons.OK,
                                MessageBoxIcon.Information);
                        }
                        else
                        {
                            form.SetUpdateStatus("更新失败：" + updateResult.Message, true, true, release);
                            MessageBox.Show(
                                form,
                                updateResult.Message,
                                "HermesGo 更新失败",
                                MessageBoxButtons.OK,
                                MessageBoxIcon.Warning);
                        }
                    }));
                    return false;
                });
            };

            if (_planOnly)
            {
                form.SetUpdateStatus("当前为 dry-run/plan-only 模式：只生成命令计划，不执行启动和更新检查。", true, false, null);
            }
            else
            {
                form.SetAvailableUpdateReleases(new List<ReleaseInfo>());
                form.SetUpdateStatus("启动器已就绪。", true, false, null);
                form.Shown += delegate
                {
                    LaunchBackgroundMaintenanceProcess();
                    StartBackgroundUpdateCheck(form, true);
                };
            }

            Application.Run(form);
        }
    }

    private async Task RunBackgroundMaintenanceAsync()
    {
        Log("background maintenance started");

        CleanupTempArtifacts();

        if (!IsSkipped())
        {
            try
            {
                var localVersion = GetLocalVersion();
                var localTag = GetLocalReleaseTag();
                var releases = await ResolveTargetReleasesAsync().ConfigureAwait(false);
                var available = releases != null
                    ? releases.Where(release => ShouldUpdateRelease(localTag, release)).ToList()
                    : new List<ReleaseInfo>();
                Log("background maintenance update probe: local=" + localVersion + ", releases=" + (releases != null ? releases.Count : 0) + ", available=" + available.Count);
            }
            catch (Exception ex)
            {
                Log("background maintenance update probe failed: " + ex.Message);
            }
        }
        else
        {
            Log("background maintenance update probe skipped by environment");
        }

        Log("background maintenance finished");
    }

    private async Task RunApplyUpdateNowAsync()
    {
        Log("apply update now started");

        if (IsSkipped())
        {
            Log("apply update now skipped by environment");
            return;
        }

        var localVersion = GetLocalVersion();
        var localTag = GetLocalReleaseTag();
        var release = await ResolveTargetReleaseAsync().ConfigureAwait(false);
        if (release == null)
        {
            Log("apply update now found no target release");
            return;
        }

        if (!ShouldUpdateRelease(localTag, release))
        {
            Log("apply update now found no newer release: local=" + localVersion + ", target=" + release.TagName);
            return;
        }

        var result = await ApplyReleaseUpdateAsync(release).ConfigureAwait(false);
        if (!result.Success)
        {
            Log("apply update now failed: " + result.Message);
            throw new InvalidOperationException(result.Message);
        }

        Log("apply update now succeeded: source=" + result.SourceLabel + ", md5=" + result.Md5 + ", bytes=" + result.Bytes.ToString(CultureInfo.InvariantCulture) + ", summary=" + (result.Summary ?? string.Empty).Replace(Environment.NewLine, " | "));
    }

    private void LaunchBackgroundMaintenanceProcess()
    {
        if (_planOnly || _backgroundMaintenance)
        {
            return;
        }

        try
        {
            var exePath = Process.GetCurrentProcess().MainModule.FileName;
            var psi = new ProcessStartInfo
            {
                FileName = exePath,
                Arguments = "--background-maintenance",
                WorkingDirectory = _root,
                UseShellExecute = false,
                CreateNoWindow = true,
                WindowStyle = ProcessWindowStyle.Hidden,
            };

            TrackLaunchedProcess(Process.Start(psi));
            Log("background maintenance process launched");
        }
        catch (Exception ex)
        {
            Log("background maintenance launch failed: " + ex.Message);
        }
    }

    private void TrackLaunchedProcess(Process process)
    {
        if (process == null)
        {
            return;
        }

        TrackLaunchedProcessId(process.Id);
    }

    private void TrackLaunchedProcessId(int processId)
    {
        if (processId <= 0)
        {
            return;
        }

        if (processId == Process.GetCurrentProcess().Id)
        {
            return;
        }

        lock (_launchedProcessLock)
        {
            _launchedProcessIds.Add(processId);
        }
    }

    private void ShutdownLaunchedProcesses()
    {
        int[] processIds;
        lock (_launchedProcessLock)
        {
            if (_shutdownRequested)
            {
                return;
            }

            _shutdownRequested = true;
            processIds = _launchedProcessIds.Where(processId => processId > 0).Distinct().ToArray();
        }

        if (processIds.Length == 0)
        {
            Log("shutdown requested, no tracked child processes were found");
            return;
        }

        Log("shutdown requested, tracked child process ids: " + string.Join(", ", processIds.Select(id => id.ToString(CultureInfo.InvariantCulture)).ToArray()));
        foreach (var processId in processIds)
        {
            KillProcessTree(processId);
        }
    }

    private void KillProcessTree(int processId)
    {
        if (processId <= 0 || processId == Process.GetCurrentProcess().Id)
        {
            return;
        }

        try
        {
            var taskkillPath = Path.Combine(Environment.SystemDirectory, "taskkill.exe");
            if (!File.Exists(taskkillPath))
            {
                taskkillPath = "taskkill.exe";
            }

            var psi = new ProcessStartInfo
            {
                FileName = taskkillPath,
                Arguments = "/F /T /PID " + processId.ToString(CultureInfo.InvariantCulture),
                WorkingDirectory = _root,
                UseShellExecute = false,
                CreateNoWindow = true,
                WindowStyle = ProcessWindowStyle.Hidden,
            };

            using (var taskkill = Process.Start(psi))
            {
                if (taskkill != null)
                {
                    taskkill.WaitForExit(10000);
                }
            }

            Log("requested process tree shutdown: PID " + processId.ToString(CultureInfo.InvariantCulture));
        }
        catch (Exception ex)
        {
            Log("failed to shut down PID " + processId.ToString(CultureInfo.InvariantCulture) + ": " + ex.Message);
        }
    }

    private void StartBackgroundUpdateCheck(LauncherForm form, bool notifyWhenAvailable)
    {
        if (form == null)
        {
            return;
        }

        if (IsSkipped())
        {
            form.SetUpdateStatus("启动器已就绪。", true, false, null);
            return;
        }

        form.SetUpdateStatus("正在后台检查 Hermes 官方更新...", false, false, null);
        Task.Run(async () =>
        {
            try
            {
                var localVersion = GetLocalVersion();
                var currentVersionText = localVersion != null ? localVersion.ToString() : "unknown";
                var localTag = GetLocalReleaseTag();
                var releases = await ResolveTargetReleasesAsync().ConfigureAwait(false);
                var available = releases != null
                    ? releases.Where(release => ShouldUpdateRelease(localTag, release)).ToList()
                    : new List<ReleaseInfo>();
                if (form.IsDisposed)
                {
                    return;
                }

                form.BeginInvoke(new Action(delegate
                {
                    if (releases == null)
                    {
                        form.SetAvailableUpdateReleases(new List<ReleaseInfo>());
                        form.SetUpdateStatus("启动器已就绪。", true, false, null);
                        return;
                    }

                    form.SetAvailableUpdateReleases(available);

                    if (available.Count > 0)
                    {
                        var selected = available[0];
                        var latestText = !string.IsNullOrWhiteSpace(selected.DisplayName) ? selected.DisplayName : selected.TagName;
                        if (available.Count > 1)
                        {
                            form.SetUpdateStatus("当前版本 " + currentVersionText + "，发现 " + available.Count + " 个官网版本，先自己选目标版本，再点“更新”。", true, true, null);
                        }
                        else
                        {
                            form.SetUpdateStatus("当前版本 " + currentVersionText + "，发现 HermesGo " + latestText + "，可从官网覆盖更新。", true, true, selected);
                        }

                        if (notifyWhenAvailable)
                        {
                            MessageBox.Show(
                                form,
                                "当前版本：" + currentVersionText + "\r\n发现可用更新：" + latestText + "\r\n\r\n可在窗口底部点击“更新”下载并覆盖 HermesGo 便携包（保留 home/data/logs）。",
                                "HermesGo 发现更新",
                                MessageBoxButtons.OK,
                                MessageBoxIcon.Information);
                        }
                    }
                    else
                    {
                        form.SetUpdateStatus("启动器已就绪。", true, false, null);
                    }
                }));
            }
            catch (Exception ex)
            {
                Log("foreground background update check failed: " + ex.Message);
                if (!form.IsDisposed)
                {
                    form.BeginInvoke(new Action(delegate
                    {
                        form.SetAvailableUpdateReleases(new List<ReleaseInfo>());
                        form.SetUpdateStatus("启动器已就绪。", true, false, null);
                    }));
                }
            }
        });
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
            try
            {
                action();
                if (_planOnly && _planEntries.Count > 0)
                {
                    WriteLauncherGuidance(
                        "HermesGo 调试计划已生成",
                        "当前是 dry-run/plan-only 模式，未执行实际命令。" + Environment.NewLine + Environment.NewLine +
                        "JSON: " + GetExePlanJsonPath() + Environment.NewLine +
                        "命令: " + GetExePlanScriptPath());
                }
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
        if (_planOnly)
        {
            AddConfigPlanEntry("apply-local-preset", "ollama", "gemma:2b", "http://127.0.0.1:11434/v1");
            LaunchPackage(new string[0]);
            return true;
        }

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
        var cloudDisplayName = string.Equals(model, "gpt-5.4-mini", StringComparison.OrdinalIgnoreCase)
            ? "Cloud: GPT-5.4 Mini"
            : "Cloud: " + (string.IsNullOrWhiteSpace(model) ? "openai-codex" : model);
        if (_planOnly)
        {
            AddConfigPlanEntry("apply-cloud-preset", "openai-codex", model, baseUrl);
            LaunchPackage(new[] {
                "-NoOpenBrowser",
                "-OAuthProvider", "openai-codex",
                "-ChatProvider", "openai-codex",
                "-ChatModel", model
            });
            OpenUrl(browserUrl);
            return true;
        }

        var state = GetLauncherState();
        if (!state.HasCodexAuth)
        {
            if (!PromptForCloudConfiguration(cloudDisplayName))
            {
                return false;
            }

            if (!PrepareCloudPreset(model, baseUrl))
            {
                return false;
            }

            LaunchPackage(new[] {
                "-NoOpenBrowser",
                "-NoOpenChat",
                "-OAuthProvider", "openai-codex",
                "-ChatProvider", "openai-codex",
                "-ChatModel", model
            });

            if (!OpenCloudDashboardOrWarn(browserUrl))
            {
                return false;
            }

            WriteLauncherGuidance(
                "需要完成 OpenAI 登录",
                "已经打开 Dashboard 的 OpenAI 登录页。请在浏览器里完成登录；登录成功后再回到启动器重新点“启动”。");
            Log("Cloud 启动暂停 - 未检测到有效 OpenAI 授权，已打开 dashboard 登录页。");
            return true;
        }

        if (!PrepareCloudPreset(model, baseUrl))
        {
            return false;
        }

        LaunchPackage(new[] {
            "-NoOpenBrowser",
            "-OAuthProvider", "openai-codex",
            "-ChatProvider", "openai-codex",
            "-ChatModel", model
        });

        if (!OpenCloudDashboardOrWarn(browserUrl))
        {
            return false;
        }

        Log("Cloud 启动已完成 - 已确认 OpenAI 登录状态并打开 dashboard。");
        return true;
    }

    private bool PrepareCloudPreset(string model, string baseUrl)
    {
        ApplyConfigPreset("openai-codex", model, baseUrl);
        var updatedState = GetLauncherState();
        if (!string.Equals(updatedState.Provider, "openai-codex", StringComparison.OrdinalIgnoreCase) ||
            !string.Equals(updatedState.Model, model, StringComparison.OrdinalIgnoreCase))
        {
            WriteLauncherGuidance(
                "云端模型配置未生效",
                "启动器已经尝试写入 openai-codex / " + model + "，但重新读取配置后仍不是这个组合。请检查 home\\config.yaml 和日志。");
            Log("cloud preset verification failed after write: provider=" + updatedState.Provider + ", model=" + updatedState.Model);
            return false;
        }

        return true;
    }

    private bool OpenCloudDashboardOrWarn(string browserUrl)
    {
        if (!WaitForUrlReady(browserUrl, TimeSpan.FromSeconds(45)))
        {
            WriteLauncherGuidance(
                "Dashboard 未就绪",
                "后台已经启动，但 Dashboard 还没有准备好。请先检查日志，或者稍后再重新点“启动”。");
            return false;
        }

        OpenUrl(browserUrl);
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
                "切换脚本没有正常结束。请先完成本地模型配置，再重新选择“Switch Model”。");
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

        private bool HandleUiSuiteSelectionLaunch(LauncherForm.UiSuiteSelection selection)
        {
            if (selection == null || selection.Ui == null)
            {
                WriteLauncherGuidance(
                    "UI 套件选择无效",
                    "请先在 UI 套件区选择一个 UI，再点顶部启动按钮。");
                return false;
            }

            var ui = selection.Ui;
            var uiId = (ui.Id ?? string.Empty).Trim();

            if (string.IsNullOrWhiteSpace(uiId))
            {
                WriteLauncherGuidance(
                    "UI 套件选择无效",
                    "所选 UI 缺少编号，请重新选择。");
                return false;
            }

            if (!TryApplyUiSuitePreset(selection.MainAction))
            {
                return false;
            }

            var arguments = new List<string>
            {
                "-Ids",
                uiId,
            };

            if (!selection.AutoOpenBrowser)
            {
                arguments.Add("-NoOpenBrowser");
            }

            if (!selection.AutoOpenChat)
            {
                arguments.Add("-NoOpenChat");
            }

            LaunchBatchScript("Start-HermesGoUiSuite.ps1", arguments.ToArray(), visible: false);
            return true;
        }

        private bool TryApplyUiSuitePreset(LauncherForm.LauncherOption option)
        {
            if (option == null)
            {
                return true;
            }

            if (string.Equals(option.Key, "beginner", StringComparison.OrdinalIgnoreCase))
            {
                if (_planOnly)
                {
                    AddConfigPlanEntry("apply-local-preset", "ollama", "gemma:2b", "http://127.0.0.1:11434/v1");
                    return true;
                }

                ApplyLocalPreset();
                return true;
            }

            if (string.Equals(option.Key, "cloud", StringComparison.OrdinalIgnoreCase))
            {
                if (_planOnly)
                {
                    AddConfigPlanEntry("apply-cloud-preset", "openai-codex", "gpt-5.4-mini", "https://chatgpt.com/backend-api/codex");
                    return true;
                }

                return PrepareCloudPreset("gpt-5.4-mini", "https://chatgpt.com/backend-api/codex");
            }

            if (!option.IsCustom || !string.Equals(option.Kind, "preset", StringComparison.OrdinalIgnoreCase))
            {
                return true;
            }

            var values = ParseLauncherValuePairs(option.Value);
            string provider;
            string model;
            string baseUrl;
            if (!values.TryGetValue("provider", out provider) || string.IsNullOrWhiteSpace(provider))
            {
                provider = "ollama";
            }
            if (!values.TryGetValue("model", out model) || string.IsNullOrWhiteSpace(model))
            {
                model = "gemma:2b";
            }
            if (!values.TryGetValue("baseUrl", out baseUrl) && !values.TryGetValue("base_url", out baseUrl))
            {
                baseUrl = string.Equals(provider, "openai-codex", StringComparison.OrdinalIgnoreCase)
                    ? "https://chatgpt.com/backend-api/codex"
                    : "http://127.0.0.1:11434/v1";
            }

            if (_planOnly)
            {
                AddConfigPlanEntry("apply-ui-suite-preset", provider, model, baseUrl);
                return true;
            }

            if (string.Equals(provider, "ollama", StringComparison.OrdinalIgnoreCase))
            {
                ApplyModelPreset(provider, model, baseUrl);
                return true;
            }

            if (string.Equals(provider, "openai-codex", StringComparison.OrdinalIgnoreCase))
            {
                return PrepareCloudPreset(model, baseUrl);
            }

            ApplyConfigPreset(provider, model, baseUrl);
            return true;
        }

        private bool HandleCodexLoginLaunch()
        {
            if (_planOnly)
            {
                RunBlockingOpenAiAuthCommand("auth", "add", "openai-codex");
                return true;
            }

            if (HasValidCodexAuth())
            {
                Log("OpenAI 登录已就绪 - 跳过登录流程，直接继续启动。");
                return true;
            }

            var exitCode = RunBlockingOpenAiAuthCommand("auth", "add", "openai-codex");
            if (exitCode != 0)
            {
                WriteLauncherGuidance(
                    "OpenAI 登录未完成",
                    "登录流程已经结束，但没有拿到有效授权。请先完成浏览器登录，再重新点“启动”。");
                return false;
            }

            var state = GetLauncherState();
            if (!state.HasCodexAuth)
            {
                WriteLauncherGuidance(
                    "OpenAI 登录已结束，但状态未刷新",
                    "请确认浏览器里的登录已经成功，然后重新打开启动器再试一次。");
                return false;
            }

            Log("OpenAI 登录成功 - 已写入 HermesGo 的 auth.json。");
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
                if (_planOnly)
                {
                    AddConfigPlanEntry("apply-custom-cloud-preset", provider, model, baseUrl);
                    LaunchPackage(new[] {
                        "-NoOpenBrowser",
                        "-OAuthProvider", provider,
                        "-ChatProvider", provider,
                        "-ChatModel", model
                    });
                    OpenUrl("http://127.0.0.1:9119/env?oauth=openai-codex");
                    return true;
                }

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
                if (_planOnly)
                {
                    AddConfigPlanEntry("apply-custom-local-preset", provider, model, baseUrl);
                    LaunchPackage(new string[0]);
                    return true;
                }

                ApplyModelPreset(provider, model, baseUrl);
                LaunchPackage(new string[0]);
                return true;
            }

            if (_planOnly)
            {
                AddConfigPlanEntry("apply-custom-preset", provider, model, baseUrl);
                LaunchPackage(new[] { "-OAuthProvider", provider, "-ChatProvider", provider, "-ChatModel", model });
                return true;
            }

            ApplyConfigPreset(provider, model, baseUrl);
            LaunchPackage(new[] { "-OAuthProvider", provider, "-ChatProvider", provider, "-ChatModel", model });
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
                && string.Equals(state.Model, "gemma:2b", StringComparison.OrdinalIgnoreCase)
                && string.Equals(state.BaseUrl, "http://127.0.0.1:11434/v1", StringComparison.OrdinalIgnoreCase);
            state.IsCloudPreset = string.Equals(state.Provider, "openai-codex", StringComparison.OrdinalIgnoreCase)
                && !string.IsNullOrWhiteSpace(state.Model);

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

                object poolObj;
                if (raw.TryGetValue("credential_pool", out poolObj))
                {
                    var pool = poolObj as Dictionary<string, object>;
                    if (pool != null)
                    {
                        object codexEntriesObj;
                        if (pool.TryGetValue("openai-codex", out codexEntriesObj))
                        {
                            var codexEntries = codexEntriesObj as object[];
                            if (codexEntries != null)
                            {
                                foreach (var entryObj in codexEntries)
                                {
                                    if (HasValidPooledCodexEntry(entryObj as Dictionary<string, object>))
                                    {
                                        return true;
                                    }
                                }
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
            return HasUsableCodexAccessToken(accessToken) && !string.IsNullOrWhiteSpace(refreshToken);
        }

        private static bool HasValidPooledCodexEntry(Dictionary<string, object> entry)
        {
            if (entry == null)
            {
                return false;
            }

            var accessToken = entry.ContainsKey("access_token") ? entry["access_token"] as string : null;
            var refreshToken = entry.ContainsKey("refresh_token") ? entry["refresh_token"] as string : null;
            return HasUsableCodexAccessToken(accessToken) && !string.IsNullOrWhiteSpace(refreshToken);
        }

        private static bool HasUsableCodexAccessToken(string accessToken)
        {
            if (string.IsNullOrWhiteSpace(accessToken))
            {
                return false;
            }

            long expiresAt;
            if (!TryReadJwtExpiration(accessToken, out expiresAt))
            {
                return true;
            }

            var now = (long)(DateTime.UtcNow - new DateTime(1970, 1, 1, 0, 0, 0, DateTimeKind.Utc)).TotalSeconds;
            return expiresAt > now + 300;
        }

        private static bool TryReadJwtExpiration(string token, out long expiresAt)
        {
            expiresAt = 0;
            var parts = (token ?? string.Empty).Split('.');
            if (parts.Length < 2)
            {
                return false;
            }

            try
            {
                var payload = parts[1].Replace('-', '+').Replace('_', '/');
                switch (payload.Length % 4)
                {
                    case 2:
                        payload += "==";
                        break;
                    case 3:
                        payload += "=";
                        break;
                }

                var json = Encoding.UTF8.GetString(Convert.FromBase64String(payload));
                var serializer = new JavaScriptSerializer();
                var claims = serializer.DeserializeObject(json) as Dictionary<string, object>;
                if (claims == null || !claims.ContainsKey("exp"))
                {
                    return false;
                }

                var value = claims["exp"];
                if (value is int)
                {
                    expiresAt = (int)value;
                    return true;
                }
                if (value is long)
                {
                    expiresAt = (long)value;
                    return true;
                }
                if (value is decimal)
                {
                    expiresAt = (long)(decimal)value;
                    return true;
                }
                if (value is double)
                {
                    expiresAt = (long)(double)value;
                    return true;
                }

                return long.TryParse(Convert.ToString(value, CultureInfo.InvariantCulture), out expiresAt);
            }
            catch
            {
                return false;
            }
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
        Log("config preset applied: provider=" + provider + ", model=" + model + ", base_url=" + baseUrl);
    }

    private void LaunchBatchScript(string scriptName, string[] args = null, bool visible = true)
    {
        var scriptPath = ResolveScriptPath(scriptName);
        if (!File.Exists(scriptPath))
        {
            Log("utility script not found: " + scriptPath);
            return;
        }

        var extension = Path.GetExtension(scriptPath) ?? string.Empty;
        ProcessStartInfo psi;
        if (string.Equals(extension, ".ps1", StringComparison.OrdinalIgnoreCase))
        {
            var psArgs = new List<string> { "-NoLogo", "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", Quote(scriptPath) };
            if (args != null)
            {
                foreach (var arg in args)
                {
                    psArgs.Add(Quote(arg));
                }
            }

            psi = new ProcessStartInfo
            {
                FileName = "powershell.exe",
                Arguments = string.Join(" ", psArgs),
                WorkingDirectory = _contentRoot,
                UseShellExecute = false,
                CreateNoWindow = !visible,
                WindowStyle = visible ? ProcessWindowStyle.Normal : ProcessWindowStyle.Hidden,
            };
        }
        else
        {
            var batchArgs = new List<string> { "/k", Quote(scriptPath) };
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
                WorkingDirectory = _contentRoot,
                UseShellExecute = false,
                CreateNoWindow = !visible,
                WindowStyle = visible ? ProcessWindowStyle.Normal : ProcessWindowStyle.Hidden,
            };
        }

        if (_planOnly)
        {
            PlanProcessStart(
                "launch-utility-script",
                psi,
                BuildScriptPlanOnlyCommandLine(scriptPath, args),
                new Dictionary<string, object>
                {
                    { "script", scriptName },
                    { "visible", visible },
                });
            return;
        }

        TrackLaunchedProcess(Process.Start(psi));
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
            WorkingDirectory = _contentRoot,
            UseShellExecute = false,
            CreateNoWindow = false,
            WindowStyle = ProcessWindowStyle.Normal,
        };

        if (_planOnly)
        {
            PlanProcessStart(
                "open-folder",
                psi,
                string.Empty,
                new Dictionary<string, object> { { "path", path } });
            return;
        }

        TrackLaunchedProcess(Process.Start(psi));
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
            WorkingDirectory = _contentRoot,
            UseShellExecute = true,
        };

        if (_planOnly)
        {
            PlanProcessStart(
                "open-text-file",
                psi,
                string.Empty,
                new Dictionary<string, object> { { "path", path } });
            return;
        }

        TrackLaunchedProcess(Process.Start(psi));
        Log("opened text file: " + path);
    }

    private int RunBlockingScript(string scriptName, string[] args = null)
    {
        var scriptPath = ResolveScriptPath(scriptName);
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
                WorkingDirectory = _contentRoot,
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
                WorkingDirectory = _contentRoot,
                UseShellExecute = false,
                CreateNoWindow = false,
                WindowStyle = ProcessWindowStyle.Normal,
            };
        }

        if (_planOnly)
        {
            PlanProcessStart(
                "run-blocking-script",
                psi,
                BuildScriptPlanOnlyCommandLine(scriptPath, args),
                new Dictionary<string, object> { { "script", scriptName } });
            return 0;
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
            WorkingDirectory = _contentRoot,
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

    private int RunBlockingOpenAiAuthCommand(params string[] arguments)
    {
        if (!File.Exists(_pythonExe))
        {
            Log("python runtime not found: " + _pythonExe);
            return 1;
        }

        var loginStdout = Path.Combine(_contentRoot, "logs", "update", "openai-codex-login.out.txt");
        var loginStderr = Path.Combine(_contentRoot, "logs", "update", "openai-codex-login.err.txt");
        Directory.CreateDirectory(Path.GetDirectoryName(loginStdout) ?? _contentRoot);
        File.WriteAllText(loginStdout, string.Empty, new UTF8Encoding(false));
        File.WriteAllText(loginStderr, string.Empty, new UTF8Encoding(false));

        var psi = new ProcessStartInfo
        {
            FileName = _pythonExe,
            Arguments = "-m hermes_cli.main " + string.Join(" ", arguments.Select(Quote)),
            WorkingDirectory = _contentRoot,
            UseShellExecute = false,
            CreateNoWindow = true,
            WindowStyle = ProcessWindowStyle.Hidden,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            StandardOutputEncoding = Encoding.UTF8,
            StandardErrorEncoding = Encoding.UTF8,
        };

        ApplyInteractiveEnvironment(psi);

        if (_planOnly)
        {
            PlanProcessStart(
                "run-openai-auth-command",
                psi,
                string.Empty,
                new Dictionary<string, object> { { "arguments", arguments.ToArray() } });
            return 0;
        }

        using (var process = Process.Start(psi))
        {
            if (process == null)
            {
                throw new InvalidOperationException("Unable to start OpenAI auth command.");
            }

            var stdout = process.StandardOutput.ReadToEndAsync();
            var stderr = process.StandardError.ReadToEndAsync();
            process.WaitForExit();
            File.WriteAllText(loginStdout, stdout.GetAwaiter().GetResult() ?? string.Empty, new UTF8Encoding(false));
            File.WriteAllText(loginStderr, stderr.GetAwaiter().GetResult() ?? string.Empty, new UTF8Encoding(false));
            Log("OpenAI auth command finished: exit=" + process.ExitCode);
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
                LaunchPackage(new[] { "-NoOpenChat", "-OAuthProvider", provider, "-ChatProvider", provider, "-ChatModel", model });
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

        if (_planOnly)
        {
            PlanProcessStart(
                "open-url",
                psi,
                string.Empty,
                new Dictionary<string, object> { { "url", url } });
            return;
        }

        TrackLaunchedProcess(Process.Start(psi));
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
            _contentRoot,
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

    private static string ResolveWindowsPowerShellExe()
    {
        var windir = Environment.GetFolderPath(Environment.SpecialFolder.Windows);
        if (string.IsNullOrWhiteSpace(windir))
        {
            windir = Environment.GetEnvironmentVariable("SystemRoot") ?? string.Empty;
        }

        var candidates = new[]
        {
            Path.Combine(windir, "System32", "WindowsPowerShell", "v1.0", "powershell.exe"),
            Path.Combine(windir, "Sysnative", "WindowsPowerShell", "v1.0", "powershell.exe"),
            "powershell.exe",
        };

        foreach (var candidate in candidates)
        {
            if (!string.IsNullOrWhiteSpace(candidate) && File.Exists(candidate))
            {
                return candidate;
            }
        }

        return "powershell.exe";
    }

    private void LaunchPackage(string[] args)
    {
        var script = ResolveScriptPath("Start-HermesGo.ps1");
        var batch = ResolveScriptPath("HermesGo.bat");
        var useScript = File.Exists(script);
        var fileName = useScript ? ResolveWindowsPowerShellExe() : Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.System), "cmd.exe");
        var arguments = useScript
            ? BuildPowerShellArguments(script, args)
            : BuildBatchArguments(batch, args);

        var psi = new ProcessStartInfo
        {
            FileName = fileName,
            Arguments = arguments,
            WorkingDirectory = _contentRoot,
            UseShellExecute = false,
            CreateNoWindow = false,
            WindowStyle = ProcessWindowStyle.Normal,
        };

        if (_planOnly)
        {
            var nextDebugCommandLine = useScript
                ? BuildCommandLine(fileName, BuildPowerShellArguments(script, AppendPlanOnlyArg(args)))
                : string.Empty;
            PlanProcessStart(
                "launch-package",
                psi,
                nextDebugCommandLine,
                new Dictionary<string, object>
                {
                    { "script", useScript ? script : batch },
                    { "args", (args ?? new string[0]).ToArray() },
                });
            return;
        }

        TrackLaunchedProcess(Process.Start(psi));
        Log(useScript ? "launched Start-HermesGo.ps1" : "launched HermesGo.bat");
    }

    private void LaunchWebUiOnly()
    {
        var batch = ResolveScriptPath("HermesWebUI.bat");
        if (!File.Exists(batch))
        {
            throw new FileNotFoundException("HermesWebUI.bat not found", batch);
        }

        var psi = new ProcessStartInfo
        {
            FileName = "cmd.exe",
            Arguments = BuildBatchArguments(batch, new string[0]),
            WorkingDirectory = _contentRoot,
            UseShellExecute = false,
            CreateNoWindow = false,
            WindowStyle = ProcessWindowStyle.Normal,
        };

        TrackLaunchedProcess(Process.Start(psi));
        Log("launched HermesWebUI.bat");
    }

    private void LaunchDesktopOnly()
    {
        var batch = ResolveScriptPath("HermesDesktop.bat");
        if (!File.Exists(batch))
        {
            throw new FileNotFoundException("HermesDesktop.bat not found", batch);
        }

        var psi = new ProcessStartInfo
        {
            FileName = "cmd.exe",
            Arguments = BuildBatchArguments(batch, new string[0]),
            WorkingDirectory = _contentRoot,
            UseShellExecute = false,
            CreateNoWindow = false,
            WindowStyle = ProcessWindowStyle.Normal,
        };

        TrackLaunchedProcess(Process.Start(psi));
        Log("launched HermesDesktop.bat");
    }

    private void AddConfigPlanEntry(string step, string provider, string model, string baseUrl)
    {
        if (!_planOnly)
        {
            return;
        }

        var details = new Dictionary<string, object>
        {
            { "provider", provider ?? string.Empty },
            { "model", model ?? string.Empty },
            { "base_url", baseUrl ?? string.Empty },
            { "target", Path.Combine(_homeDir, "config.yaml") },
        };

        AddPlanEntry(new CommandPlanEntry
        {
            StepName = step,
            Kind = "config",
            Details = details,
        });
    }

    private void PlanProcessStart(string step, ProcessStartInfo psi, string nextDebugCommandLine, Dictionary<string, object> details)
    {
        if (psi == null)
        {
            return;
        }

        AddPlanEntry(new CommandPlanEntry
        {
            StepName = step,
            Kind = "process",
            FileName = psi.FileName ?? string.Empty,
            Arguments = psi.Arguments ?? string.Empty,
            WorkingDirectory = psi.WorkingDirectory ?? string.Empty,
            UseShellExecute = psi.UseShellExecute,
            CreateNoWindow = psi.CreateNoWindow,
            WindowStyle = psi.WindowStyle.ToString(),
            CommandLine = BuildCommandLine(psi.FileName, psi.Arguments),
            NextDebugCommandLine = nextDebugCommandLine ?? string.Empty,
            Details = details ?? new Dictionary<string, object>(),
        });
    }

    private void AddPlanEntry(CommandPlanEntry entry)
    {
        if (entry == null)
        {
            return;
        }

        entry.Step = _planEntries.Count + 1;
        entry.GeneratedAt = DateTimeOffset.Now.ToString("o", CultureInfo.InvariantCulture);
        _planEntries.Add(entry);
        WritePlanFiles();
        Log("planned command step " + entry.Step + ": " + entry.StepName);
    }

    private string GetExePlanJsonPath()
    {
        return Path.Combine(_contentRoot, "logs", "last-exe-command-plan.json");
    }

    private string GetExePlanScriptPath()
    {
        return Path.Combine(_contentRoot, "logs", "last-exe-command-plan.ps1");
    }

    private void WritePlanFiles()
    {
        var logDir = Path.Combine(_contentRoot, "logs");
        Directory.CreateDirectory(logDir);

        var serializer = new JavaScriptSerializer
        {
            MaxJsonLength = int.MaxValue,
        };
        var plan = new Dictionary<string, object>
        {
            { "schema", 1 },
            { "generated_at", DateTimeOffset.Now.ToString("o", CultureInfo.InvariantCulture) },
            { "plan_only", true },
            { "source", "HermesGo.exe" },
            { "content_root", _contentRoot },
            { "commands", _planEntries },
        };

        File.WriteAllText(GetExePlanJsonPath(), serializer.Serialize(plan), new UTF8Encoding(false));
        File.WriteAllText(GetExePlanScriptPath(), BuildPlanScript(), new UTF8Encoding(false));
    }

    private string BuildPlanScript()
    {
        var builder = new StringBuilder();
        builder.AppendLine("# HermesGo dry-run command plan.");
        builder.AppendLine("# This file is generated by HermesGo.exe and does not run anything by itself.");
        builder.AppendLine("# Copy one command at a time when debugging.");
        builder.AppendLine();

        foreach (var entry in _planEntries)
        {
            builder.AppendLine("# Step " + entry.Step.ToString(CultureInfo.InvariantCulture) + ": " + entry.StepName);
            if (!string.IsNullOrWhiteSpace(entry.CommandLine))
            {
                builder.AppendLine("# Actual command:");
                builder.AppendLine("# " + entry.CommandLine);
            }
            if (!string.IsNullOrWhiteSpace(entry.NextDebugCommandLine))
            {
                builder.AppendLine("# Next debug command:");
                builder.AppendLine("# " + entry.NextDebugCommandLine);
            }
            if (string.Equals(entry.Kind, "config", StringComparison.OrdinalIgnoreCase) && entry.Details != null)
            {
                builder.AppendLine("# Config change:");
                foreach (var pair in entry.Details)
                {
                    builder.AppendLine("# " + pair.Key + " = " + Convert.ToString(pair.Value, CultureInfo.InvariantCulture));
                }
            }
            builder.AppendLine();
        }

        return builder.ToString();
    }

    private string BuildScriptPlanOnlyCommandLine(string scriptPath, string[] args)
    {
        if (string.IsNullOrWhiteSpace(scriptPath))
        {
            return string.Empty;
        }

        var scriptName = Path.GetFileName(scriptPath) ?? string.Empty;
        if (!string.Equals(Path.GetExtension(scriptPath), ".ps1", StringComparison.OrdinalIgnoreCase))
        {
            return string.Empty;
        }

        if (!SupportsPlanOnlyScript(scriptName))
        {
            return string.Empty;
        }

        return BuildCommandLine("powershell.exe", BuildPowerShellArguments(scriptPath, AppendPlanOnlyArg(args)));
    }

    private static bool SupportsPlanOnlyScript(string scriptName)
    {
        return string.Equals(scriptName, "Start-HermesGo.ps1", StringComparison.OrdinalIgnoreCase);
    }

    private static string[] AppendPlanOnlyArg(string[] args)
    {
        var result = new List<string>(args ?? new string[0]);
        if (!result.Any(arg => string.Equals(arg, "-PlanOnly", StringComparison.OrdinalIgnoreCase)))
        {
            result.Add("-PlanOnly");
        }

        return result.ToArray();
    }

    private static string BuildCommandLine(string fileName, string arguments)
    {
        var command = Quote(fileName ?? string.Empty);
        if (!string.IsNullOrWhiteSpace(arguments))
        {
            command += " " + arguments.Trim();
        }

        return command;
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

    private string ResolveScriptPath(string scriptName)
    {
        if (string.IsNullOrWhiteSpace(scriptName))
        {
            return string.Empty;
        }

        if (Path.IsPathRooted(scriptName))
        {
            return scriptName;
        }

        var scriptsCandidate = Path.Combine(_scriptsDir, scriptName);
        if (File.Exists(scriptsCandidate))
        {
            return scriptsCandidate;
        }

        return Path.Combine(_contentRoot, scriptName);
    }

    private string ResolveToolPath(string toolName)
    {
        if (string.IsNullOrWhiteSpace(toolName))
        {
            return string.Empty;
        }

        if (Path.IsPathRooted(toolName))
        {
            return toolName;
        }

        var toolsCandidate = Path.Combine(_toolsDir, toolName);
        if (File.Exists(toolsCandidate))
        {
            return toolsCandidate;
        }

        return Path.Combine(_contentRoot, toolName);
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

    private sealed class CommandPlanEntry
    {
        public int Step { get; set; }
        public string StepName { get; set; }
        public string Kind { get; set; }
        public string GeneratedAt { get; set; }
        public string FileName { get; set; }
        public string Arguments { get; set; }
        public string WorkingDirectory { get; set; }
        public bool UseShellExecute { get; set; }
        public bool CreateNoWindow { get; set; }
        public string WindowStyle { get; set; }
        public string CommandLine { get; set; }
        public string NextDebugCommandLine { get; set; }
        public Dictionary<string, object> Details { get; set; }
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

        public sealed class UiSuiteModelItem
        {
            public string Id { get; set; }
            public string Label { get; set; }
            public string Provider { get; set; }
            public string Model { get; set; }
            public string BaseUrl { get; set; }
            public string Description { get; set; }
            public string OAuthProvider { get; set; }

            public override string ToString()
            {
                return Label ?? string.Empty;
            }
        }

        public sealed class UiSuiteUiItem
        {
            public string Id { get; set; }
            public string Name { get; set; }
            public string Description { get; set; }
            public string DefaultUrl { get; set; }

            public override string ToString()
            {
                return string.Format("{0} {1}", Id ?? string.Empty, Name ?? string.Empty).Trim();
            }
        }

        public sealed class UiSuiteSelection
        {
            public UiSuiteUiItem Ui { get; set; }
            public LauncherOption MainAction { get; set; }
            public bool AutoOpenBrowser { get; set; }
            public bool AutoOpenChat { get; set; }
        }

        public event EventHandler BeginnerRequested;
        public event EventHandler FullLaunchRequested;
        public event EventHandler WebUiOnlyRequested;
        public event EventHandler DesktopOnlyRequested;
        public event EventHandler CloudRequested;
        public event EventHandler ExpertRequested;
        public event EventHandler SwitchModelRequested;
        public event EventHandler VerifyRequested;
        public event EventHandler CodexLoginRequested;
        public event EventHandler<UiSuiteSelection> UiSuiteLaunchRequested;
        public event EventHandler OpenHomeRequested;
        public event EventHandler OpenLogsRequested;
        public event EventHandler OpenCustomActionsRequested;
        public event EventHandler<LauncherOption> CustomActionRequested;
        public event EventHandler ExitRequested;
        public event EventHandler UpdateRequested;

        private enum LaunchTarget
        {
            MainAction,
            UiSuite,
        }

        private ComboBox _selectionBox;
        private Label _selectionDescription;
        private Panel _uiSuitePanel;
        private TableLayoutPanel _mainPanel;
        private Button _launchButton;
        private Label _uiSuiteHintLabel;
        private ListBox _uiSuiteListBox;
        private Label _uiSuiteSelectedTitle;
        private TextBox _uiSuiteUiDescription;
        private CheckBox _uiSuiteBrowserCheckBox;
        private CheckBox _uiSuiteChatCheckBox;
        private Label _updateStatusLabel;
        private ProgressBar _updateProgressBar;
        private ComboBox _updateReleaseBox;
        private Button _updateButton;
        private readonly LauncherState _launcherState;
        private readonly List<LauncherOption> _launcherOptions = new List<LauncherOption>();
        private readonly List<ReleaseInfo> _availableUpdateReleases = new List<ReleaseInfo>();
        private ReleaseInfo _pendingUpdate;
        private bool _updateReady;
        private LaunchTarget _launchTarget = LaunchTarget.MainAction;

        public ReleaseInfo PendingUpdate { get { return _pendingUpdate; } }

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
            AutoScaleMode = AutoScaleMode.None;
            AutoScaleDimensions = new SizeF(96F, 96F);
            FormBorderStyle = FormBorderStyle.Sizable;
            MaximizeBox = true;
            MinimizeBox = true;
            ShowInTaskbar = true;
            ClientSize = GetScaledClientSize(1040, 720);
            MinimumSize = GetScaledClientSize(960, 640);
            AutoScroll = true;
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
                Text = "绿色便携版：Dashboard + WebUI + Desktop 三件套。双击 exe 与 HermesGo.bat 相同直接启动；加 --menu 可打开本菜单。",
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

            _mainPanel = new TableLayoutPanel
            {
                Dock = DockStyle.Fill,
                BackColor = BackColor,
                Padding = new Padding(12, 0, 0, 0),
                ColumnCount = 1,
                RowCount = 6,
            };
            _mainPanel.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100F));
            _mainPanel.RowStyles.Add(new RowStyle(SizeType.Absolute, 58F));
            _mainPanel.RowStyles.Add(new RowStyle(SizeType.Absolute, 34F));
            _mainPanel.RowStyles.Add(new RowStyle(SizeType.Absolute, 178F));
            _mainPanel.RowStyles.Add(new RowStyle(SizeType.Absolute, 340F));
            _mainPanel.RowStyles.Add(new RowStyle(SizeType.Absolute, 34F));
            _mainPanel.RowStyles.Add(new RowStyle(SizeType.Absolute, 56F));

            var header = new Label
            {
                AutoSize = false,
                Dock = DockStyle.Top,
                Height = 58,
                Font = new Font(Font.FontFamily, 18F, FontStyle.Bold),
                ForeColor = Color.FromArgb(30, 30, 35),
                Text = "HermesGo 启动菜单（--menu）",
            };

            var subtitle = new Label
            {
                AutoSize = false,
                Dock = DockStyle.Top,
                Height = 34,
                ForeColor = Color.FromArgb(96, 96, 110),
                Text = "默认第一项与 HermesGo.bat 相同；也可单独启动 WebUI 或 Desktop。",
            };

            var actionPanel = new Panel
            {
                Dock = DockStyle.Top,
                Height = 178,
                BackColor = Color.FromArgb(236, 240, 246),
                Padding = new Padding(12),
            };

            var actionLayout = new TableLayoutPanel
            {
                Dock = DockStyle.Fill,
                ColumnCount = 1,
                RowCount = 3,
                BackColor = Color.Transparent,
                Margin = new Padding(0),
                Padding = new Padding(0),
            };
            actionLayout.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100F));
            actionLayout.RowStyles.Add(new RowStyle(SizeType.Absolute, 20F));
            actionLayout.RowStyles.Add(new RowStyle(SizeType.Absolute, 34F));
            actionLayout.RowStyles.Add(new RowStyle(SizeType.Percent, 100F));

            var actionTitle = new Label
            {
                AutoSize = false,
                Dock = DockStyle.Fill,
                ForeColor = Color.FromArgb(70, 72, 80),
                Font = new Font(Font.FontFamily, 10F, FontStyle.Bold),
                Text = "HermesGo 主启动与维护",
                TextAlign = ContentAlignment.MiddleLeft,
                Margin = new Padding(0),
            };

            var actionControls = new TableLayoutPanel
            {
                Dock = DockStyle.Fill,
                ColumnCount = 2,
                RowCount = 1,
                BackColor = Color.Transparent,
                Margin = new Padding(0),
                Padding = new Padding(0),
            };
            actionControls.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100F));
            actionControls.ColumnStyles.Add(new ColumnStyle(SizeType.Absolute, 120F));
            actionControls.RowStyles.Add(new RowStyle(SizeType.Percent, 100F));

            _selectionBox = new ComboBox
            {
                Dock = DockStyle.Fill,
                DropDownStyle = ComboBoxStyle.DropDownList,
                Font = new Font(Font.FontFamily, 10F, FontStyle.Regular),
                Margin = new Padding(0, 1, 8, 0),
            };
            _selectionBox.SelectedIndexChanged += delegate { UpdateSelectionDescription(); };
            _selectionBox.KeyDown += delegate(object sender, KeyEventArgs e)
            {
                if (e != null && e.KeyCode == Keys.Enter)
                {
                    ExecuteCurrentLaunch();
                    e.Handled = true;
                    e.SuppressKeyPress = true;
                }
            };
            _selectionBox.DoubleClick += delegate { ExecuteCurrentLaunch(); };

            _launchButton = new Button
            {
                Dock = DockStyle.Fill,
                Text = "启动",
                FlatStyle = FlatStyle.Flat,
                BackColor = Color.FromArgb(41, 142, 98),
                ForeColor = Color.White,
                UseVisualStyleBackColor = false,
                Margin = new Padding(0, 0, 8, 0),
            };
            _launchButton.FlatAppearance.BorderSize = 0;
            _launchButton.Click += delegate { ExecuteCurrentLaunch(); };

            actionControls.Controls.Add(_selectionBox, 0, 0);
            actionControls.Controls.Add(_launchButton, 1, 0);

            _selectionDescription = new Label
            {
                AutoSize = false,
                Dock = DockStyle.Fill,
                ForeColor = Color.FromArgb(88, 90, 100),
                Text = "选中后点“启动”；底部可检查并安装 wangkj123/HermesGo 官网新版本。",
                TextAlign = ContentAlignment.TopLeft,
                Margin = new Padding(0, 6, 0, 0),
            };
            _selectionDescription.Visible = true;

            actionLayout.Controls.Add(actionTitle, 0, 0);
            actionLayout.Controls.Add(actionControls, 0, 1);
            actionLayout.Controls.Add(_selectionDescription, 0, 2);
            actionPanel.Controls.Add(actionLayout);

            PopulateLauncherOptions(_launcherState);
            BuildUiSuitePanel();
            RefreshLaunchTarget();

            var footer = new Label
            {
                AutoSize = false,
                Dock = DockStyle.Bottom,
                Height = 34,
                ForeColor = Color.FromArgb(110, 110, 120),
                Text = "自动更新会下载 green-3ui-slim 便携 zip，保留 home/data/logs。",
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
                Height = 56,
            };

            _updateStatusLabel = new Label
            {
                AutoSize = false,
                Dock = DockStyle.Top,
                Height = 20,
                TextAlign = ContentAlignment.MiddleLeft,
                ForeColor = Color.FromArgb(95, 95, 108),
                Text = "启动器已就绪。",
            };

            _updateProgressBar = new ProgressBar
            {
                Dock = DockStyle.Bottom,
                Height = 9,
                Visible = false,
                Style = ProgressBarStyle.Marquee,
                MarqueeAnimationSpeed = 24,
                Minimum = 0,
                Maximum = 100,
            };

            var updateStatusPanel = new Panel
            {
                Dock = DockStyle.Fill,
                BackColor = Color.Transparent,
                Margin = new Padding(0),
                Padding = new Padding(0),
            };
            updateStatusPanel.Controls.Add(_updateProgressBar);
            updateStatusPanel.Controls.Add(_updateStatusLabel);

            _updateReleaseBox = new ComboBox
            {
                Width = 220,
                Height = 28,
                DropDownStyle = ComboBoxStyle.DropDownList,
                Font = new Font(Font.FontFamily, 9.5F, FontStyle.Regular),
                Visible = false,
                Enabled = false,
                Margin = new Padding(0, 4, 8, 0),
            };
            _updateReleaseBox.SelectedIndexChanged += delegate { UpdateSelectedUpdateRelease(); };

            _updateButton = new Button
            {
                Text = "检查更新",
                Width = 112,
                Height = 34,
                Visible = true,
                Enabled = true,
                FlatStyle = FlatStyle.Flat,
                BackColor = Color.FromArgb(41, 142, 98),
                ForeColor = Color.White,
                UseVisualStyleBackColor = false,
                Margin = new Padding(0, 3, 0, 0),
            };
            _updateButton.FlatAppearance.BorderSize = 0;
            _updateButton.Click += delegate { OnUpdateRequested(); };

            var updateControls = new FlowLayoutPanel
            {
                Dock = DockStyle.Right,
                Width = 346,
                Height = 40,
                FlowDirection = FlowDirection.LeftToRight,
                WrapContents = false,
                BackColor = Color.Transparent,
                Margin = new Padding(0),
                Padding = new Padding(0),
            };
            updateControls.Controls.Add(_updateReleaseBox);
            updateControls.Controls.Add(_updateButton);

            footerRow.Controls.Add(updateStatusPanel);
            footerRow.Controls.Add(updateControls);
            footerRow.Controls.Add(exitButton);

            _mainPanel.Controls.Add(header, 0, 0);
            _mainPanel.Controls.Add(subtitle, 0, 1);
            _mainPanel.Controls.Add(actionPanel, 0, 2);
            _mainPanel.Controls.Add(_uiSuitePanel, 0, 3);
            _mainPanel.Controls.Add(footer, 0, 4);
            _mainPanel.Controls.Add(footerRow, 0, 5);

            layout.Controls.Add(heroPanel, 0, 0);
            layout.Controls.Add(_mainPanel, 1, 0);

            AcceptButton = _launchButton;
        }

        private string GetPackageRoot()
        {
            var exeDir = Path.GetDirectoryName(Application.ExecutablePath) ?? string.Empty;
            var appDir = Path.Combine(exeDir, "app");
            return Directory.Exists(appDir) ? appDir : exeDir;
        }

        private static Size GetScaledClientSize(int baseWidth, int baseHeight)
        {
            var workingArea = Screen.PrimaryScreen.WorkingArea;
            var width = Math.Max(1, Math.Min(baseWidth, workingArea.Width - 40));
            var height = Math.Max(1, Math.Min(baseHeight, workingArea.Height - 40));
            return new Size(width, height);
        }

        private static float GetDisplayScaleFactor()
        {
            try
            {
                using (var graphics = Graphics.FromHwnd(IntPtr.Zero))
                {
                    if (graphics != null && graphics.DpiX > 0)
                    {
                        return graphics.DpiX / 96F;
                    }
                }
            }
            catch
            {
                // Fall back to 1.0 when the desktop DPI cannot be queried.
            }

            return 1F;
        }

        private string GetHomeDir()
        {
            return Path.Combine(GetPackageRoot(), "home");
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
                "; UI 套件主入口已经集成到 HermesGo.exe 里。",
                "; 需要说明时直接打开 app\\ui-suite\\docs\\README.md。",
                string.Empty,
            });

            File.WriteAllText(path, template, Encoding.UTF8);
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
                Key = "full-3ui",
                Text = "启动三件套（Dashboard + WebUI + Desktop）",
                Description = "与 HermesGo.bat 相同：启动 Start-HermesGo.ps1，打开 Dashboard、WebUI 和 Desktop。",
                Kind = "full-3ui",
            });
            builtIns.Add(new LauncherOption
            {
                Key = "webui-only",
                Text = "仅 WebUI",
                Description = "与 HermesWebUI.bat 相同，只启动聊天 WebUI（8787）。",
                Kind = "webui-only",
            });
            builtIns.Add(new LauncherOption
            {
                Key = "desktop-only",
                Text = "仅 Desktop",
                Description = "与 HermesDesktop.bat 相同，只启动 Electron 桌面端。",
                Kind = "desktop-only",
            });
            builtIns.Add(new LauncherOption
            {
                Key = "verify",
                Text = "自检",
                Description = "运行 Verify-HermesGo，不进入主界面。",
                Kind = "verify",
            });
            builtIns.Add(new LauncherOption
            {
                Key = "open-home",
                Text = "打开 home 目录",
                Description = "打开绿色版 home 目录（配置与数据）。",
                Kind = "open-home",
            });
            builtIns.Add(new LauncherOption
            {
                Key = "open-logs",
                Text = "打开 logs 目录",
                Description = "打开绿色版 logs 目录。",
                Kind = "open-logs",
            });

            _launcherOptions.AddRange(builtIns);
            _launcherOptions.AddRange(LoadCustomLauncherOptions());

            _selectionBox.Items.Clear();
            var orderedOptions = new List<LauncherOption>(_launcherOptions);
            var defaultKey = "full-3ui";

            var preferredKey = defaultKey;
            var selected = orderedOptions.FirstOrDefault(item => string.Equals(item.Key, preferredKey, StringComparison.OrdinalIgnoreCase))
                ?? orderedOptions.FirstOrDefault(item => string.Equals(item.Key, defaultKey, StringComparison.OrdinalIgnoreCase))
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
            RefreshLaunchTarget();
            if (_selectionDescription == null)
            {
                return;
            }

            var option = GetSelectedLauncherOption();
            _selectionDescription.Text = option != null ? BuildSelectionSummary(option) : string.Empty;
        }

        private void SetLaunchTarget(LaunchTarget target)
        {
            _launchTarget = target;
            if (_launchButton != null)
            {
                _launchButton.Text = target == LaunchTarget.UiSuite ? "启动 UI" : "启动";
            }
        }

        private void ExecuteCurrentLaunch()
        {
            if (_launchTarget == LaunchTarget.UiSuite)
            {
                RaiseUiSuiteLaunchRequested();
                return;
            }

            ExecuteSelectedAction();
        }

        private void ExecuteSelectedAction()
        {
            var option = GetSelectedLauncherOption();
            if (option == null)
            {
                return;
            }

            if (string.Equals(option.Key, "full-3ui", StringComparison.OrdinalIgnoreCase))
            {
                OnFullLaunchRequested();
                return;
            }

            if (string.Equals(option.Key, "webui-only", StringComparison.OrdinalIgnoreCase))
            {
                OnWebUiOnlyRequested();
                return;
            }

            if (string.Equals(option.Key, "desktop-only", StringComparison.OrdinalIgnoreCase))
            {
                OnDesktopOnlyRequested();
                return;
            }

            if (string.Equals(option.Key, "verify", StringComparison.OrdinalIgnoreCase))
            {
                OnVerifyRequested();
                return;
            }

            if (string.Equals(option.Key, "open-home", StringComparison.OrdinalIgnoreCase))
            {
                OnOpenHomeRequested();
                return;
            }

            if (string.Equals(option.Key, "open-logs", StringComparison.OrdinalIgnoreCase))
            {
                OnOpenLogsRequested();
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

        private string BuildSelectionSummary(LauncherOption option)
        {
            var lines = new List<string>();
            var description = option.Description ?? string.Empty;
            var firstLine = description
                .Split(new[] { "\r\n", "\n" }, StringSplitOptions.None)
                .FirstOrDefault(line => !string.IsNullOrWhiteSpace(line));
            if (!string.IsNullOrWhiteSpace(firstLine))
            {
                lines.Add(firstLine.Trim());
            }

            var statusLines = BuildSelectionStatusLines(option);
            if (statusLines.Count > 0)
            {
                lines.Add("当前检测：" + string.Join("；", statusLines.ToArray()));
            }

            lines.Add("更新功能在窗口底部。");
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
                if (ShouldUseUiSuiteLaunch())
                {
                    lines.Add("组合启动：当前选中的 UI 套件会和这个预设一起执行。");
                }
            }
            else if (string.Equals(option.Key, "cloud", StringComparison.OrdinalIgnoreCase))
            {
                lines.Add(state.HasCodexAuth
                    ? "OpenAI 登录：已就绪。"
                    : "OpenAI 登录：未就绪，点“启动”会先打开登录流程。");
                if (string.Equals(model, "gpt-5.4-mini", StringComparison.OrdinalIgnoreCase))
                {
                    lines.Add("当前状态：Cloud 默认配置已对齐到 gpt-5.4 mini。");
                }
                else
                {
                    lines.Add("当前状态：会先把模型切回 gpt-5.4 mini 再启动。");
                }
                if (ShouldUseUiSuiteLaunch())
                {
                    lines.Add("组合启动：当前选中的 UI 套件会和这个预设一起执行。");
                }
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
                    ? "OpenAI 登录：已检测到有效授权。"
                    : "OpenAI 登录：未检测到有效授权，启动后会打开登录流程。");
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
                            ? "OpenAI 登录：已就绪，启动后会直接继续。"
                            : "OpenAI 登录：未就绪，启动后会先弹出配置确认框，再走登录流程。");
                    }
                    if (ShouldUseUiSuiteLaunch())
                    {
                        lines.Add("组合启动：当前选中的 UI 套件会和这个预设一起执行。");
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
                var exeDir = Path.GetDirectoryName(Application.ExecutablePath) ?? string.Empty;
                var contentRoot = Directory.Exists(Path.Combine(exeDir, "app"))
                    ? Path.Combine(exeDir, "app")
                    : exeDir;
                var logoCandidates = new[]
                {
                    Path.Combine(contentRoot, "assets", "HermesGo-logo.png"),
                    Path.Combine(contentRoot, "assets", "branding", "HermesGo-logo.png"),
                    Path.Combine(exeDir, "HermesGo-logo.png"),
                };

                foreach (var logoPath in logoCandidates)
                {
                    if (!File.Exists(logoPath))
                    {
                        continue;
                    }

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

        private void BuildUiSuitePanel()
        {
            if (_uiSuitePanel != null)
            {
                return;
            }

            _uiSuitePanel = new Panel
            {
                Dock = DockStyle.Fill,
                Visible = false,
                Height = 0,
                BackColor = BackColor,
                Margin = new Padding(0),
                Padding = new Padding(0),
            };

            if (_mainPanel != null && _mainPanel.RowStyles.Count > 3)
            {
                _mainPanel.RowStyles[3] = new RowStyle(SizeType.Absolute, 0F);
            }
        }

        private void UpdateUiSuiteDialogDescriptions()
        {
            RefreshLaunchTarget();
            if (_uiSuiteUiDescription == null)
            {
                return;
            }

            if (_uiSuiteHintLabel != null)
            {
                var selectedUi = GetSelectedUiSuiteUi();
                _uiSuiteHintLabel.ForeColor = Color.FromArgb(102, 98, 88);
                if (selectedUi != null && !string.Equals(selectedUi.Id, "00", StringComparison.OrdinalIgnoreCase))
                {
                    _uiSuiteHintLabel.Text = ShouldUseUiSuiteLaunch()
                        ? "当前选择会按“预设 + UI 套件”组合启动；浏览器和 Hermes CLI 复选框默认都勾选。"
                        : "当前选中的 UI 会保留主启动区；只有 Beginner / Cloud 这类预设会和 UI 套件组合启动。";
                }
                else
                {
                    _uiSuiteHintLabel.Text = "选中 00 原版时，主按钮按主启动区执行；浏览器和 Hermes CLI 复选框默认都勾选。";
                }
            }

            var ui = GetSelectedUiSuiteUi();
            if (ui != null)
            {
                _uiSuiteUiDescription.Text = string.Join(Environment.NewLine, new[]
                {
                    "ID: " + ui.Id,
                    "Name: " + ui.Name,
                    "Entry: " + ui.DefaultUrl,
                    string.Empty,
                    ui.Description ?? string.Empty,
                });
            }
            else
            {
                _uiSuiteUiDescription.Text = string.Empty;
            }
        }

        private UiSuiteUiItem GetSelectedUiSuiteUi()
        {
            return _uiSuiteListBox != null ? _uiSuiteListBox.SelectedItem as UiSuiteUiItem : null;
        }

        private UiSuiteSelection BuildUiSuiteSelection()
        {
            return new UiSuiteSelection
            {
                Ui = GetSelectedUiSuiteUi(),
                MainAction = GetSelectedLauncherOption(),
                AutoOpenBrowser = _uiSuiteBrowserCheckBox == null || _uiSuiteBrowserCheckBox.Checked,
                AutoOpenChat = _uiSuiteChatCheckBox == null || _uiSuiteChatCheckBox.Checked,
            };
        }

        private void RaiseUiSuiteLaunchRequested()
        {
            var selection = BuildUiSuiteSelection();
            if (selection.Ui == null)
            {
                if (_uiSuiteHintLabel != null)
                {
                    _uiSuiteHintLabel.ForeColor = Color.FromArgb(160, 72, 48);
                    _uiSuiteHintLabel.Text = "请先选择一个 UI，再点顶部启动按钮。";
                }
                return;
            }

            var handler = UiSuiteLaunchRequested;
            if (handler != null)
            {
                handler(this, selection);
            }
        }

        private bool IsPresetLauncherOption(LauncherOption option)
        {
            if (option == null)
            {
                return false;
            }

            if (string.Equals(option.Key, "beginner", StringComparison.OrdinalIgnoreCase) ||
                string.Equals(option.Key, "cloud", StringComparison.OrdinalIgnoreCase))
            {
                return true;
            }

            return option.IsCustom && string.Equals(option.Kind, "preset", StringComparison.OrdinalIgnoreCase);
        }

        private bool ShouldUseUiSuiteLaunch()
        {
            var ui = GetSelectedUiSuiteUi();
            if (ui == null || string.Equals(ui.Id, "00", StringComparison.OrdinalIgnoreCase))
            {
                return false;
            }

            return IsPresetLauncherOption(GetSelectedLauncherOption());
        }

        private void RefreshLaunchTarget()
        {
            SetLaunchTarget(ShouldUseUiSuiteLaunch() ? LaunchTarget.UiSuite : LaunchTarget.MainAction);
        }

        private void OnBeginnerRequested()
        {
            var handler = BeginnerRequested;
            if (handler != null)
            {
                handler(this, EventArgs.Empty);
            }
        }

        private void OnFullLaunchRequested()
        {
            var handler = FullLaunchRequested;
            if (handler != null)
            {
                handler(this, EventArgs.Empty);
            }
        }

        private void OnWebUiOnlyRequested()
        {
            var handler = WebUiOnlyRequested;
            if (handler != null)
            {
                handler(this, EventArgs.Empty);
            }
        }

        private void OnDesktopOnlyRequested()
        {
            var handler = DesktopOnlyRequested;
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

        public void SetUpdateStatus(string text, bool ready, bool showButton, ReleaseInfo release)
        {
            _updateReady = ready;
            if (_updateStatusLabel != null)
            {
                _updateStatusLabel.Text = text ?? string.Empty;
            }

            if (_updateProgressBar != null)
            {
                var busy = !ready && !showButton;
                _updateProgressBar.Visible = busy;
                if (busy)
                {
                    _updateProgressBar.Style = ProgressBarStyle.Marquee;
                    _updateProgressBar.MarqueeAnimationSpeed = 24;
                }
            }

            if (_updateButton != null)
            {
                _updateButton.Visible = showButton;
            }

            if (!showButton)
            {
                _pendingUpdate = null;
            }
            else if (_pendingUpdate == null && release != null)
            {
                _pendingUpdate = release;
            }

            UpdateSelectedUpdateRelease();
        }

        public void SetAvailableUpdateReleases(IReadOnlyList<ReleaseInfo> releases)
        {
            _availableUpdateReleases.Clear();
            if (releases != null)
            {
                foreach (var release in releases)
                {
                    if (release != null)
                    {
                        _availableUpdateReleases.Add(release);
                    }
                }
            }

            if (_updateReleaseBox != null)
            {
                _updateReleaseBox.BeginUpdate();
                try
                {
                    _updateReleaseBox.Items.Clear();
                    foreach (var release in _availableUpdateReleases)
                    {
                        _updateReleaseBox.Items.Add(release);
                    }

                    _updateReleaseBox.Visible = _availableUpdateReleases.Count > 1;
                    _updateReleaseBox.Enabled = _availableUpdateReleases.Count > 0;
                    if (_availableUpdateReleases.Count == 1)
                    {
                        _updateReleaseBox.SelectedIndex = 0;
                    }
                    else if (_availableUpdateReleases.Count > 1)
                    {
                        _updateReleaseBox.SelectedIndex = -1;
                    }
                }
                finally
                {
                    _updateReleaseBox.EndUpdate();
                }
            }

            _pendingUpdate = _availableUpdateReleases.Count == 1 ? _availableUpdateReleases[0] : null;
            UpdateSelectedUpdateRelease();
        }

        private void UpdateSelectedUpdateRelease()
        {
            if (_updateReleaseBox != null && _updateReleaseBox.SelectedIndex >= 0 && _updateReleaseBox.SelectedIndex < _availableUpdateReleases.Count)
            {
                _pendingUpdate = _availableUpdateReleases[_updateReleaseBox.SelectedIndex];
            }
            else if (_availableUpdateReleases.Count == 0)
            {
                _pendingUpdate = null;
            }

            if (_updateButton != null)
            {
                if (_availableUpdateReleases.Count == 0)
                {
                    _updateButton.Text = "检查更新";
                    _updateButton.Enabled = _updateReady && _updateButton.Visible;
                }
                else
                {
                    _updateButton.Text = "更新";
                    _updateButton.Enabled = _updateReady && _updateButton.Visible && _pendingUpdate != null;
                }
            }
        }

        private void OnUpdateRequested()
        {
            var handler = UpdateRequested;
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

    private sealed class ReleaseInfo
    {
        public string TagName { get; set; }
        public string DisplayName { get; set; }
        public string Body { get; set; }
        public string SourceZipUrl { get; set; }
        public Version AgentVersion { get; set; }
        public List<string> ZipAssetNames { get; set; }
        public List<string> ZipAssetUrls { get; set; }

        public override string ToString()
        {
            if (!string.IsNullOrWhiteSpace(DisplayName))
            {
                return DisplayName.Trim();
            }

            return string.IsNullOrWhiteSpace(TagName) ? "release" : TagName.Trim();
        }
    }

    private sealed class UpdateResult
    {
        private readonly bool _success;
        private readonly string _message;
        private readonly string _sourceLabel;
        private readonly string _md5;
        private readonly long _bytes;
        private readonly string _summary;

        private UpdateResult(bool success, string message, string sourceLabel, string md5, long bytes, string summary)
        {
            _success = success;
            _message = message;
            _sourceLabel = sourceLabel;
            _md5 = md5;
            _bytes = bytes;
            _summary = summary;
        }

        public bool Success { get { return _success; } }
        public string Message { get { return _message; } }
        public string SourceLabel { get { return _sourceLabel; } }
        public string Md5 { get { return _md5; } }
        public long Bytes { get { return _bytes; } }
        public string Summary { get { return _summary; } }

        public static UpdateResult Successful(string sourceLabel, string md5, long bytes, string summary)
        {
            return new UpdateResult(true, string.Empty, sourceLabel, md5, bytes, summary);
        }

        public static UpdateResult Failed(string message)
        {
            return new UpdateResult(false, message, string.Empty, string.Empty, 0, string.Empty);
        }
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
