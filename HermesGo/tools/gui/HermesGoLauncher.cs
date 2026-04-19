using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Drawing;
using System.IO;
using System.Text;
using System.Text.RegularExpressions;
using System.Threading.Tasks;
using System.Windows.Forms;

namespace HermesGoLauncher
{
    internal static class Program
    {
        [STAThread]
        private static void Main()
        {
            Application.EnableVisualStyles();
            Application.SetCompatibleTextRenderingDefault(false);
            if (string.Equals(Environment.GetEnvironmentVariable("HERMESGO_LAUNCHER_SELFTEST"), "1", StringComparison.OrdinalIgnoreCase))
            {
                using (var form = new LauncherForm())
                {
                    Environment.ExitCode = form.RunLauncherSelfTest();
                    return;
                }
            }

            Application.Run(new LauncherForm());
        }
    }

    internal sealed class HermesConfig
    {
        public string Provider { get; set; }
        public string Model { get; set; }
        public string BaseUrl { get; set; }
    }

    internal sealed class HermesDefaults
    {
        public string Provider { get; set; }
        public string Model { get; set; }
        public string BaseUrl { get; set; }
    }

    internal sealed class LocalModelOption
    {
        public string Model { get; set; }
        public bool Installed { get; set; }
        public bool Current { get; set; }

        public string DisplayText
        {
            get
            {
                string state = Installed ? "可用" : "缺失，启动时下载";
                string suffix = Current ? " (当前)" : string.Empty;
                return string.Format("[{0}] {1}{2}", state, Model, suffix);
            }
        }

        public override string ToString()
        {
            return DisplayText;
        }
    }

    internal sealed class LauncherForm : Form
    {
        private readonly string appRoot = ResolveAppRoot();
        private readonly string toolsDir;
        private readonly string homeDir;
        private readonly string configPath;
        private readonly string defaultsPath;
        private readonly string usagePath;
        private readonly string envPath;
        private readonly string logsDir;
        private readonly string dashboardUrl = "http://127.0.0.1:9119/";
        private readonly string startScript;
        private readonly string hermesExe;
        private readonly string automationSnapshotPath;
        private readonly HermesDefaults portableDefaults;

        private readonly ComboBox presetBox = new ComboBox();
        private readonly TextBox providerBox = new TextBox();
        private readonly ComboBox modelBox = new ComboBox();
        private readonly TextBox baseUrlBox = new TextBox();
        private readonly RichTextBox logBox = new RichTextBox();
        private readonly Label statusLabel = new Label();
        private readonly Label summaryLabel = new Label();
        private readonly Button loadButton = new Button();
        private readonly Button saveButton = new Button();
        private readonly Button saveStartButton = new Button();
        private readonly Button switchModelButton = new Button();
        private readonly Button startButton = new Button();
        private readonly Button dashboardButton = new Button();
        private readonly Button codexButton = new Button();
        private readonly Button usageButton = new Button();
        private readonly Button logsButton = new Button();
        private readonly Button configButton = new Button();
        private readonly Button envButton = new Button();
        private readonly Button exitButton = new Button();
        private readonly Button applyPresetButton = new Button();
        private bool isRefreshingModelChoices;
        private bool isApplyingPreset;
        private DateTime localModelCacheTimeUtc = DateTime.MinValue;
        private string localModelCacheKey = string.Empty;
        private string lastNormalizedProvider = string.Empty;
        private readonly List<string> cachedInstalledLocalModels = new List<string>();

        private static string NormalizePortablePath(string path)
        {
            if (string.IsNullOrWhiteSpace(path))
            {
                return path ?? string.Empty;
            }

            string trimmed = path.Trim().TrimEnd(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar);
            Match tsclient = Regex.Match(trimmed, @"^\\\\tsclient\\(?<drive>[A-Za-z])(?<rest>(?:\\.*)?)$");
            if (tsclient.Success)
            {
                return tsclient.Groups["drive"].Value.ToUpperInvariant() + ":" + tsclient.Groups["rest"].Value;
            }

            return trimmed;
        }

        private static string ResolveAppRoot()
        {
            string overrideRoot = Environment.GetEnvironmentVariable("HERMESGO_APP_ROOT");
            if (!string.IsNullOrWhiteSpace(overrideRoot))
            {
                return NormalizePortablePath(overrideRoot);
            }

            return NormalizePortablePath(AppContext.BaseDirectory);
        }

        public LauncherForm()
        {
            toolsDir = Path.Combine(appRoot, "tools");
            homeDir = Path.Combine(appRoot, "home");
            configPath = Path.Combine(homeDir, "config.yaml");
            defaultsPath = Path.Combine(homeDir, "portable-defaults.txt");
            usagePath = Path.Combine(appRoot, "使用说明.txt");
            envPath = Path.Combine(homeDir, ".env");
            logsDir = Path.Combine(appRoot, "logs");
            startScript = Path.Combine(toolsDir, "Start-HermesGo.ps1");
            hermesExe = Path.Combine(appRoot, "runtime", "python311", "python.exe");
            automationSnapshotPath = Environment.GetEnvironmentVariable("HERMESGO_CONTROL_MAP_PATH") ?? string.Empty;
            portableDefaults = LoadPortableDefaults();

            Text = "HermesGo 启动器";
            StartPosition = FormStartPosition.CenterScreen;
            Width = 1080;
            Height = 760;
            MinimumSize = new Size(960, 680);
            BackColor = Color.White;
            Icon = TryLoadIcon();

            BuildUi();
            LoadConfigIntoForm();
            Shown += delegate { WriteAutomationSnapshotIfRequested(); };
        }

        private Icon TryLoadIcon()
        {
            try
            {
                string iconPath = Path.Combine(appRoot, "assets", "HermesGo.ico");
                if (File.Exists(iconPath))
                {
                    return new Icon(iconPath);
                }
            }
            catch
            {
            }

            try
            {
                return Icon.ExtractAssociatedIcon(Application.ExecutablePath);
            }
            catch
            {
                return SystemIcons.Application;
            }
        }

        private void BuildUi()
        {
            Font = new Font("Segoe UI", 10F, FontStyle.Regular, GraphicsUnit.Point);

            var root = new TableLayoutPanel();
            root.Dock = DockStyle.Fill;
            root.Padding = new Padding(16);
            root.RowCount = 4;
            root.ColumnCount = 1;
            root.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100F));
            root.RowStyles.Add(new RowStyle(SizeType.Absolute, 72F));
            root.RowStyles.Add(new RowStyle(SizeType.Absolute, 250F));
            root.RowStyles.Add(new RowStyle(SizeType.Absolute, 170F));
            root.RowStyles.Add(new RowStyle(SizeType.Percent, 100F));
            Controls.Add(root);

            var header = new Panel();
            header.Dock = DockStyle.Fill;

            var title = new Label();
            title.Text = "HermesGo 启动器";
            title.AutoSize = true;
            title.Font = new Font(Font.FontFamily, 18F, FontStyle.Bold);
            title.Location = new Point(0, 0);

            summaryLabel.AutoSize = false;
            summaryLabel.Location = new Point(2, 38);
            summaryLabel.Size = new Size(1000, 24);
            summaryLabel.Text = "正在读取配置...";

            statusLabel.AutoSize = false;
            statusLabel.Location = new Point(0, 56);
            statusLabel.Size = new Size(1000, 18);
            statusLabel.ForeColor = Color.DimGray;
            statusLabel.Text = "GUI 启动器已就绪。";

            header.Controls.Add(title);
            header.Controls.Add(summaryLabel);
            header.Controls.Add(statusLabel);
            root.Controls.Add(header, 0, 0);

            var configGroup = new GroupBox();
            configGroup.Text = "模型与 Provider 配置";
            configGroup.Dock = DockStyle.Fill;

            var configLayout = new TableLayoutPanel();
            configLayout.Dock = DockStyle.Fill;
            configLayout.Padding = new Padding(12, 20, 12, 12);
            configLayout.ColumnCount = 4;
            configLayout.RowCount = 4;
            configLayout.ColumnStyles.Add(new ColumnStyle(SizeType.Absolute, 110F));
            configLayout.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 50F));
            configLayout.ColumnStyles.Add(new ColumnStyle(SizeType.Absolute, 100F));
            configLayout.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 50F));
            configLayout.RowStyles.Add(new RowStyle(SizeType.Absolute, 34F));
            configLayout.RowStyles.Add(new RowStyle(SizeType.Absolute, 34F));
            configLayout.RowStyles.Add(new RowStyle(SizeType.Absolute, 34F));
            configLayout.RowStyles.Add(new RowStyle(SizeType.Absolute, 44F));
            configGroup.Controls.Add(configLayout);

            var presetLabel = new Label();
            presetLabel.Text = "模型预设";
            presetLabel.AutoSize = true;
            presetLabel.TextAlign = ContentAlignment.MiddleLeft;
            presetLabel.Anchor = AnchorStyles.Left;
            configLayout.Controls.Add(presetLabel, 0, 0);

            presetBox.DropDownStyle = ComboBoxStyle.DropDownList;
            presetBox.Name = "presetBox";
            presetBox.AccessibleName = "presetBox";
            presetBox.Items.AddRange(new object[]
            {
                "自定义",
                string.Format("本地 Ollama ({0})", portableDefaults.Model),
                "Codex (gpt-5.4-mini)",
                "OpenRouter (gpt-4.1-mini)"
            });
            presetBox.SelectedIndex = 0;
            presetBox.Dock = DockStyle.Fill;
            presetBox.SelectionChangeCommitted += ApplyPresetButton_Click;
            configLayout.Controls.Add(presetBox, 1, 0);

            applyPresetButton.Text = "应用预设";
            applyPresetButton.Dock = DockStyle.Fill;
            applyPresetButton.Click += ApplyPresetButton_Click;
            configLayout.Controls.Add(applyPresetButton, 2, 0);

            var openConfigButton = new Button();
            openConfigButton.Text = "打开 config";
            openConfigButton.Dock = DockStyle.Fill;
            openConfigButton.Click += delegate { OpenFile(configPath); };
            configLayout.Controls.Add(openConfigButton, 3, 0);

            var providerLabel = new Label();
            providerLabel.Text = "Provider";
            providerLabel.AutoSize = true;
            providerLabel.Anchor = AnchorStyles.Left;
            configLayout.Controls.Add(providerLabel, 0, 1);

            providerBox.Dock = DockStyle.Fill;
            providerBox.Name = "providerBox";
            providerBox.AccessibleName = "providerBox";
            providerBox.Text = portableDefaults.Provider;
            providerBox.TextChanged += ProviderBox_TextChanged;
            configLayout.Controls.Add(providerBox, 1, 1);

            var modelLabel = new Label();
            modelLabel.Text = "Model";
            modelLabel.AutoSize = true;
            modelLabel.Anchor = AnchorStyles.Left;
            configLayout.Controls.Add(modelLabel, 2, 1);

            modelBox.Dock = DockStyle.Fill;
            modelBox.DropDownStyle = ComboBoxStyle.DropDownList;
            modelBox.Name = "modelBox";
            modelBox.AccessibleName = "modelBox";
            modelBox.AutoCompleteMode = AutoCompleteMode.None;
            modelBox.AutoCompleteSource = AutoCompleteSource.None;
            modelBox.IntegralHeight = false;
            modelBox.MaxDropDownItems = 12;
            modelBox.Text = portableDefaults.Model;
            modelBox.SelectedIndexChanged += delegate
            {
                UpdateSummary();
                WriteAutomationSnapshotIfRequested();
            };
            configLayout.Controls.Add(modelBox, 3, 1);
            RefreshModelChoices(modelBox.Text.Trim());

            var baseUrlLabel = new Label();
            baseUrlLabel.Text = "Base URL";
            baseUrlLabel.AutoSize = true;
            baseUrlLabel.Anchor = AnchorStyles.Left;
            configLayout.Controls.Add(baseUrlLabel, 0, 2);

            baseUrlBox.Dock = DockStyle.Fill;
            baseUrlBox.Name = "baseUrlBox";
            baseUrlBox.AccessibleName = "baseUrlBox";
            baseUrlBox.Text = portableDefaults.BaseUrl;
            configLayout.Controls.Add(baseUrlBox, 1, 2);

            var empty = new Label();
            empty.Text = "";
            configLayout.Controls.Add(empty, 2, 2);

            var note = new Label();
            note.Text = "Codex 登录/换号会自动打开 Dashboard 登录页；本地模型可直接点“切换本地模型”，或改 Model 后保存。";
            note.AutoSize = false;
            note.Dock = DockStyle.Fill;
            note.TextAlign = ContentAlignment.MiddleLeft;
            configLayout.SetColumnSpan(note, 2);
            configLayout.Controls.Add(note, 1, 2);

            var configButtons = new FlowLayoutPanel();
            configButtons.Dock = DockStyle.Fill;
            configButtons.FlowDirection = FlowDirection.LeftToRight;
            configButtons.WrapContents = false;

            loadButton.Text = "重新读取";
            loadButton.Name = "loadButton";
            loadButton.AccessibleName = "loadButton";
            loadButton.Click += delegate { LoadConfigIntoForm(); };
            saveButton.Text = "保存配置";
            saveButton.Name = "saveButton";
            saveButton.AccessibleName = "saveButton";
            saveButton.Click += SaveButton_Click;
            saveStartButton.Text = "保存并启动";
            saveStartButton.Name = "saveStartButton";
            saveStartButton.AccessibleName = "saveStartButton";
            saveStartButton.Click += SaveStartButton_Click;
            switchModelButton.Text = "切换本地模型";
            switchModelButton.Name = "switchModelButton";
            switchModelButton.AccessibleName = "switchModelButton";
            switchModelButton.Click += SwitchModelButton_Click;
            configButtons.Controls.Add(loadButton);
            configButtons.Controls.Add(saveButton);
            configButtons.Controls.Add(saveStartButton);
            configButtons.Controls.Add(switchModelButton);
            configLayout.Controls.Add(configButtons, 1, 3);
            configLayout.SetColumnSpan(configButtons, 3);

            root.Controls.Add(configGroup, 0, 1);

            var actionGroup = new GroupBox();
            actionGroup.Text = "启动与账号";
            actionGroup.Dock = DockStyle.Fill;

            var actionLayout = new TableLayoutPanel();
            actionLayout.Dock = DockStyle.Fill;
            actionLayout.Padding = new Padding(12, 20, 12, 12);
            actionLayout.ColumnCount = 4;
            actionLayout.RowCount = 2;
            actionLayout.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 25F));
            actionLayout.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 25F));
            actionLayout.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 25F));
            actionLayout.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 25F));
            actionLayout.RowStyles.Add(new RowStyle(SizeType.Absolute, 38F));
            actionLayout.RowStyles.Add(new RowStyle(SizeType.Absolute, 38F));
            actionGroup.Controls.Add(actionLayout);

            startButton.Text = "启动 HermesGo";
            startButton.Name = "startButton";
            startButton.AccessibleName = "startButton";
            startButton.Dock = DockStyle.Fill;
            startButton.Click += StartButton_Click;
            actionLayout.Controls.Add(startButton, 0, 0);

            dashboardButton.Text = "只开 Dashboard";
            dashboardButton.Name = "dashboardButton";
            dashboardButton.AccessibleName = "dashboardButton";
            dashboardButton.Dock = DockStyle.Fill;
            dashboardButton.Click += DashboardButton_Click;
            actionLayout.Controls.Add(dashboardButton, 1, 0);

            codexButton.Text = "登录/换号 Codex";
            codexButton.Name = "codexButton";
            codexButton.AccessibleName = "codexButton";
            codexButton.Dock = DockStyle.Fill;
            codexButton.Click += CodexButton_Click;
            actionLayout.Controls.Add(codexButton, 2, 0);

            usageButton.Text = "打开使用说明";
            usageButton.Name = "usageButton";
            usageButton.AccessibleName = "usageButton";
            usageButton.Dock = DockStyle.Fill;
            usageButton.Click += delegate { OpenFile(usagePath); };
            actionLayout.Controls.Add(usageButton, 3, 0);

            logsButton.Text = "打开日志";
            logsButton.Name = "logsButton";
            logsButton.AccessibleName = "logsButton";
            logsButton.Dock = DockStyle.Fill;
            logsButton.Click += delegate { OpenFolder(logsDir); };
            actionLayout.Controls.Add(logsButton, 0, 1);

            configButton.Text = "打开 .env";
            configButton.Name = "configButton";
            configButton.AccessibleName = "configButton";
            configButton.Dock = DockStyle.Fill;
            configButton.Click += delegate { OpenFile(envPath); };
            actionLayout.Controls.Add(configButton, 1, 1);

            var dashboardOpenButton = new Button();
            dashboardOpenButton.Text = "打开浏览器";
            dashboardOpenButton.Dock = DockStyle.Fill;
            dashboardOpenButton.Click += delegate { OpenUrl(dashboardUrl); };
            actionLayout.Controls.Add(dashboardOpenButton, 2, 1);

            exitButton.Text = "退出";
            exitButton.Name = "exitButton";
            exitButton.AccessibleName = "exitButton";
            exitButton.Dock = DockStyle.Fill;
            exitButton.Click += delegate { Close(); };
            actionLayout.Controls.Add(exitButton, 3, 1);

            root.Controls.Add(actionGroup, 0, 2);

            var logGroup = new GroupBox();
            logGroup.Text = "运行日志";
            logGroup.Dock = DockStyle.Fill;

            logBox.Dock = DockStyle.Fill;
            logBox.ReadOnly = true;
            logBox.Font = new Font("Consolas", 10F, FontStyle.Regular, GraphicsUnit.Point);
            logBox.BackColor = Color.FromArgb(248, 248, 248);
            logGroup.Controls.Add(logBox);
            root.Controls.Add(logGroup, 0, 3);

            AppendLog("HermesGo 启动器已启动。");
        }

        private HermesConfig LoadConfig()
        {
            HermesConfig cfg = new HermesConfig();
            cfg.Provider = portableDefaults.Provider;
            cfg.Model = portableDefaults.Model;
            cfg.BaseUrl = portableDefaults.BaseUrl;

            if (!File.Exists(configPath))
            {
                return cfg;
            }

            string text = File.ReadAllText(configPath, Encoding.UTF8);
            string provider = MatchValue(text, @"(?m)^\s*provider:\s*""?(?<v>[^""\r\n]+)""?\s*$");
            string model = MatchValue(text, @"(?m)^\s*default:\s*""?(?<v>[^""\r\n]+)""?\s*$");
            string baseUrl = MatchValue(text, @"(?m)^\s*base_url:\s*""?(?<v>[^""\r\n]+)""?\s*$");

            if (!string.IsNullOrWhiteSpace(provider))
            {
                cfg.Provider = provider.Trim();
            }
            if (!string.IsNullOrWhiteSpace(model))
            {
                cfg.Model = model.Trim();
            }
            if (!string.IsNullOrWhiteSpace(baseUrl))
            {
                cfg.BaseUrl = baseUrl.Trim();
            }

            return cfg;
        }

        private void LoadConfigIntoForm()
        {
            HermesConfig cfg = LoadConfig();
            providerBox.Text = cfg.Provider;
            modelBox.Text = cfg.Model;
            baseUrlBox.Text = cfg.BaseUrl;
            RefreshModelChoices(modelBox.Text.Trim());
            UpdateLocalPresetLabel(modelBox.Text.Trim());
            UpdateProviderSpecificUi();
            UpdateSummary();
            AppendLog("已从 home/config.yaml 读取当前配置。");
            WriteAutomationSnapshotIfRequested();
        }

        private void UpdateSummary()
        {
            summaryLabel.Text = string.Format(
                "当前配置: provider={0} | model={1} | base_url={2}",
                providerBox.Text.Trim(),
                modelBox.Text.Trim(),
                baseUrlBox.Text.Trim());
        }

        private HermesDefaults LoadPortableDefaults()
        {
            HermesDefaults defaults = new HermesDefaults();
            defaults.Provider = "ollama";
            defaults.Model = "gemma:2b";
            defaults.BaseUrl = "http://127.0.0.1:11434/v1";

            if (!File.Exists(defaultsPath))
            {
                return defaults;
            }

            try
            {
                string text = File.ReadAllText(defaultsPath, Encoding.UTF8);
                string provider = MatchValue(text, @"(?m)^\s*DEFAULT_OLLAMA_PROVIDER\s*=\s*(?<v>[^#\r\n]+)");
                string model = MatchValue(text, @"(?m)^\s*DEFAULT_OLLAMA_MODEL\s*=\s*(?<v>[^#\r\n]+)");
                string baseUrl = MatchValue(text, @"(?m)^\s*DEFAULT_OLLAMA_BASE_URL\s*=\s*(?<v>[^#\r\n]+)");

                if (!string.IsNullOrWhiteSpace(provider))
                {
                    defaults.Provider = provider.Trim().Trim('"');
                }
                if (!string.IsNullOrWhiteSpace(model))
                {
                    defaults.Model = model.Trim().Trim('"');
                }
                if (!string.IsNullOrWhiteSpace(baseUrl))
                {
                    defaults.BaseUrl = baseUrl.Trim().Trim('"');
                }
            }
            catch
            {
            }

            return defaults;
        }

        private void SaveConfigFromForm()
        {
            if (!Directory.Exists(homeDir))
            {
                Directory.CreateDirectory(homeDir);
            }

            AutoMatchProviderFromModel();

            string text = File.Exists(configPath)
                ? File.ReadAllText(configPath, Encoding.UTF8)
                : DefaultConfigContent();

            text = ReplaceYamlValue(text, "default", modelBox.Text.Trim());
            text = ReplaceYamlValue(text, "provider", providerBox.Text.Trim());
            text = ReplaceYamlValue(text, "base_url", baseUrlBox.Text.Trim());

            File.WriteAllText(configPath, text, new UTF8Encoding(false));

            if (string.Equals(providerBox.Text.Trim(), "ollama", StringComparison.OrdinalIgnoreCase))
            {
                portableDefaults.Provider = "ollama";
                portableDefaults.Model = modelBox.Text.Trim();
                portableDefaults.BaseUrl = string.IsNullOrWhiteSpace(baseUrlBox.Text)
                    ? "http://127.0.0.1:11434/v1"
                    : baseUrlBox.Text.Trim();
                SavePortableDefaults();
                RefreshModelChoices(portableDefaults.Model);
            }
        }

        private void AutoMatchProviderFromModel()
        {
            string model = modelBox.Text.Trim();
            if (IsLikelyOllamaModel(model))
            {
                providerBox.Text = "ollama";
                if (string.IsNullOrWhiteSpace(baseUrlBox.Text) || !IsLocalOllamaBaseUrl(baseUrlBox.Text.Trim()))
                {
                    baseUrlBox.Text = string.IsNullOrWhiteSpace(portableDefaults.BaseUrl)
                        ? "http://127.0.0.1:11434/v1"
                        : portableDefaults.BaseUrl;
                }
            }
        }

        private static bool IsLikelyOllamaModel(string model)
        {
            if (string.IsNullOrWhiteSpace(model))
            {
                return false;
            }

            return model.IndexOf(':') > 0 && model.IndexOf('/') < 0 && !model.StartsWith("gpt-", StringComparison.OrdinalIgnoreCase);
        }

        private static bool IsLocalOllamaBaseUrl(string baseUrl)
        {
            if (string.IsNullOrWhiteSpace(baseUrl))
            {
                return false;
            }

            try
            {
                Uri uri = new Uri(baseUrl);
                return string.Equals(uri.Host, "127.0.0.1", StringComparison.OrdinalIgnoreCase)
                    || string.Equals(uri.Host, "localhost", StringComparison.OrdinalIgnoreCase);
            }
            catch
            {
                return false;
            }
        }

        private string DefaultConfigContent()
        {
            return string.Join(
                Environment.NewLine,
                new string[]
                {
                    "model:",
                    string.Format("  default: \"{0}\"", portableDefaults.Model),
                    string.Format("  provider: \"{0}\"", portableDefaults.Provider),
                    string.Format("  base_url: \"{0}\"", portableDefaults.BaseUrl),
                    "",
                    "terminal:",
                    "  backend: \"local\"",
                    "  cwd: \".\"",
                    "  timeout: 180",
                    "  lifetime_seconds: 300",
                    ""
                });
        }

        private static string ReplaceYamlValue(string text, string key, string value)
        {
            string escaped = EscapeYamlDoubleQuoted(value);
            string pattern = string.Format(@"(?m)^(\s*{0}:\s*).*$", Regex.Escape(key));
            string replacement = string.Format("$1\"{0}\"", escaped);
            string updated = Regex.Replace(text, pattern, replacement, RegexOptions.Multiline);
            return updated;
        }

        private static string EscapeYamlDoubleQuoted(string value)
        {
            if (value == null)
            {
                return string.Empty;
            }
            return value.Replace("\\", "\\\\").Replace("\"", "\\\"");
        }

        private static string MatchValue(string text, string pattern)
        {
            Match match = Regex.Match(text, pattern, RegexOptions.Multiline);
            if (!match.Success)
            {
                return null;
            }
            return match.Groups["v"].Value;
        }

        private async void SaveButton_Click(object sender, EventArgs e)
        {
            await SaveAndReportAsync(false);
        }

        private async void SaveStartButton_Click(object sender, EventArgs e)
        {
            await SaveAndReportAsync(true);
        }

        private async Task SaveAndReportAsync(bool startAfterSave)
        {
            await SaveAndReportAsync(startAfterSave, false, false);
        }

        private async Task SaveAndReportAsync(bool startAfterSave, bool noOpenBrowser, bool noOpenChat)
        {
            try
            {
                SaveConfigFromForm();
                UpdateLocalPresetLabel(modelBox.Text.Trim());
                UpdateSummary();
                AppendLog("已保存 home/config.yaml。");
                if (startAfterSave)
                {
                    await StartHermesAsync(noOpenBrowser, noOpenChat);
                }
                else
                {
                    SetStatus("配置已保存。");
                }
            }
            catch (Exception ex)
            {
                AppendLog("保存失败: " + ex.Message);
                MessageBox.Show(this, ex.Message, "保存失败", MessageBoxButtons.OK, MessageBoxIcon.Error);
            }
        }

        private async void StartButton_Click(object sender, EventArgs e)
        {
            await SaveAndReportAsync(true, false, false);
        }

        private async void DashboardButton_Click(object sender, EventArgs e)
        {
            await SaveAndReportAsync(true, true, true);
        }

        private async void CodexButton_Click(object sender, EventArgs e)
        {
            await LoginCodexAsync();
        }

        private void ApplyPresetButton_Click(object sender, EventArgs e)
        {
            if (isApplyingPreset)
            {
                return;
            }

            isApplyingPreset = true;
            try
            {
            string preset = presetBox.SelectedItem == null ? "自定义" : presetBox.SelectedItem.ToString();
            if (preset.IndexOf("Ollama", StringComparison.OrdinalIgnoreCase) >= 0)
            {
                providerBox.Text = "ollama";
                modelBox.Text = portableDefaults.Model;
                baseUrlBox.Text = portableDefaults.BaseUrl;
                UpdateLocalPresetLabel(modelBox.Text.Trim());
            }
            else if (preset.StartsWith("Codex", StringComparison.OrdinalIgnoreCase))
            {
                providerBox.Text = "openai-codex";
                modelBox.Text = "gpt-5.4-mini";
                baseUrlBox.Text = GetPreferredCodexBaseUrl();
            }
            else if (preset.StartsWith("OpenRouter", StringComparison.OrdinalIgnoreCase))
            {
                providerBox.Text = "openrouter";
                modelBox.Text = "openai/gpt-4.1-mini";
                baseUrlBox.Text = "https://openrouter.ai/api/v1";
            }

            RefreshModelChoices(modelBox.Text.Trim());
            UpdateProviderSpecificUi();
            UpdateSummary();
            SetStatus("预设已应用，先保存再启动。");
            WriteAutomationSnapshotIfRequested();
            }
            finally
            {
                isApplyingPreset = false;
            }
        }

        private void SwitchModelButton_Click(object sender, EventArgs e)
        {
            try
            {
                List<LocalModelOption> models = GetLocalModelOptions(modelBox.Text.Trim());
                if (models.Count == 0)
                {
                    MessageBox.Show(
                        this,
                        "没有可显示的本地 Ollama 模型。\n可以在 Model 中手动输入 Ollama 模型名后保存启动。",
                        "没有可切换的模型",
                        MessageBoxButtons.OK,
                        MessageBoxIcon.Information);
                    return;
                }

                string selected = ShowLocalModelPicker(modelBox.Text.Trim(), models);
                if (string.IsNullOrWhiteSpace(selected))
                {
                    return;
                }

                ApplyLocalModelSelection(selected.Trim());
                MessageBox.Show(
                    this,
                    "已切换本地模型为: " + selected.Trim(),
                    "切换完成",
                    MessageBoxButtons.OK,
                    MessageBoxIcon.Information);
            }
            catch (Exception ex)
            {
                AppendLog("切换本地模型失败: " + ex.Message);
                MessageBox.Show(this, ex.Message, "切换失败", MessageBoxButtons.OK, MessageBoxIcon.Error);
            }
        }

        private List<LocalModelOption> GetLocalModelOptions(string currentModel)
        {
            var models = new List<LocalModelOption>();
            var seen = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
            foreach (string installedModel in GetInstalledLocalModels())
            {
                AddLocalModelOption(models, seen, installedModel, true, currentModel);
            }

            foreach (string model in GetSuggestedLocalModels(currentModel))
            {
                AddLocalModelOption(models, seen, model, false, currentModel);
            }

            models.Sort((a, b) =>
            {
                if (a.Current && !b.Current)
                {
                    return -1;
                }
                if (!a.Current && b.Current)
                {
                    return 1;
                }
                if (a.Installed && !b.Installed)
                {
                    return -1;
                }
                if (!a.Installed && b.Installed)
                {
                    return 1;
                }

                return StringComparer.OrdinalIgnoreCase.Compare(a.Model, b.Model);
            });
            return models;
        }

        private IEnumerable<string> GetInstalledLocalModels()
        {
            string manifestsRoot = Path.Combine(appRoot, "data", "ollama", "models", "manifests", "registry.ollama.ai", "library");
            string cacheKey = manifestsRoot + "|" + (Directory.Exists(manifestsRoot) ? Directory.GetLastWriteTimeUtc(manifestsRoot).Ticks.ToString() : "missing");
            if (string.Equals(localModelCacheKey, cacheKey, StringComparison.Ordinal) &&
                (DateTime.UtcNow - localModelCacheTimeUtc).TotalSeconds < 2)
            {
                foreach (string cached in cachedInstalledLocalModels)
                {
                    yield return cached;
                }
                yield break;
            }

            var refreshed = new List<string>();
            try
            {
                if (Directory.Exists(manifestsRoot))
                {
                    foreach (string libraryDir in Directory.GetDirectories(manifestsRoot))
                    {
                        string library = Path.GetFileName(libraryDir);
                        if (string.IsNullOrWhiteSpace(library))
                        {
                            continue;
                        }

                        foreach (string manifestPath in Directory.GetFiles(libraryDir))
                        {
                            string tag = Path.GetFileName(manifestPath);
                            if (string.IsNullOrWhiteSpace(tag))
                            {
                                continue;
                            }

                            refreshed.Add(library + ":" + tag);
                        }
                    }
                }
            }
            catch (Exception ex)
            {
                AppendLog("读取本地 Ollama 模型目录失败: " + ex.Message);
            }

            refreshed.Sort(StringComparer.OrdinalIgnoreCase);
            cachedInstalledLocalModels.Clear();
            cachedInstalledLocalModels.AddRange(refreshed);
            localModelCacheKey = cacheKey;
            localModelCacheTimeUtc = DateTime.UtcNow;

            foreach (string model in cachedInstalledLocalModels)
            {
                yield return model;
            }
        }

        private void AddLocalModelOption(List<LocalModelOption> models, HashSet<string> seen, string model, bool installed, string currentModel)
        {
            if (string.IsNullOrWhiteSpace(model))
            {
                return;
            }

            string normalized = model.Trim();
            if (seen.Contains(normalized))
            {
                return;
            }

            seen.Add(normalized);
            models.Add(new LocalModelOption
            {
                Model = normalized,
                Installed = installed,
                Current = string.Equals(normalized, currentModel, StringComparison.OrdinalIgnoreCase)
            });
        }

        private IEnumerable<string> GetBaseSuggestedLocalModels()
        {
            if (!string.IsNullOrWhiteSpace(portableDefaults.Model))
            {
                yield return portableDefaults.Model.Trim();
            }

            yield return "gemma:2b";
            yield return "qwen2.5:0.5b";
            yield return "qwen2.5:1.5b";
            yield return "qwen2.5-coder:0.5b";
            yield return "llama3.2:1b";
            yield return "llama3.2:3b";
            yield return "phi3:mini";
        }

        private IEnumerable<string> GetSuggestedLocalModels(string currentModel)
        {
            if (!string.IsNullOrWhiteSpace(currentModel))
            {
                yield return currentModel.Trim();
            }

            foreach (string model in GetBaseSuggestedLocalModels())
            {
                yield return model;
            }
        }

        private IEnumerable<string> GetProviderModels(string provider, string currentModel)
        {
            string normalizedProvider = NormalizeProvider(provider);
            if (normalizedProvider == "ollama")
            {
                foreach (string model in GetInstalledLocalModels())
                {
                    yield return model;
                }
                foreach (string model in GetSuggestedLocalModels(currentModel))
                {
                    yield return model;
                }
                yield break;
            }

            if (normalizedProvider == "openai-codex")
            {
                yield return "gpt-5.4-mini";
                yield return "gpt-5.4";
                yield return "gpt-5.3-codex";
                yield return "gpt-5.3-codex-spark";
                yield return "gpt-5.2-codex";
                yield return "gpt-5.1-codex-max";
                yield return "gpt-5.1-codex-mini";
                yield break;
            }

            if (normalizedProvider == "openrouter")
            {
                yield return "openai/gpt-4.1-mini";
                yield return "openai/gpt-4.1";
                yield return "anthropic/claude-sonnet-4";
                yield return "google/gemini-2.5-flash";
                yield break;
            }
        }

        private IEnumerable<string> GetSuggestedModels(string provider, string currentModel)
        {
            string normalizedProvider = NormalizeProvider(provider);
            if (normalizedProvider == "ollama")
            {
                if (!string.IsNullOrWhiteSpace(currentModel))
                {
                    yield return currentModel.Trim();
                }

                foreach (string model in GetProviderModels(normalizedProvider, currentModel))
                {
                    yield return model;
                }
                yield break;
            }

            if (string.IsNullOrWhiteSpace(normalizedProvider))
            {
                if (!string.IsNullOrWhiteSpace(currentModel))
                {
                    yield return currentModel.Trim();
                }
                yield break;
            }

            foreach (string model in GetProviderModels(normalizedProvider, currentModel))
            {
                yield return model;
            }
        }

        private void ProviderBox_TextChanged(object sender, EventArgs e)
        {
            string normalizedProvider = NormalizeProvider(providerBox.Text);
            string selectedModel = modelBox.Text.Trim();
            if (!string.Equals(normalizedProvider, lastNormalizedProvider, StringComparison.Ordinal))
            {
                selectedModel = GetDefaultModelForProvider(normalizedProvider, selectedModel);
                lastNormalizedProvider = normalizedProvider;
            }

            RefreshModelChoices(selectedModel);
            UpdateProviderSpecificUi();
            UpdateSummary();
            WriteAutomationSnapshotIfRequested();
        }

        private string GetDefaultModelForProvider(string provider, string currentModel)
        {
            string normalizedProvider = NormalizeProvider(provider);
            string trimmedCurrent = string.IsNullOrWhiteSpace(currentModel) ? string.Empty : currentModel.Trim();

            if (normalizedProvider == "ollama")
            {
                if (!string.IsNullOrWhiteSpace(trimmedCurrent) && IsKnownLocalModel(trimmedCurrent))
                {
                    return trimmedCurrent;
                }

                return string.IsNullOrWhiteSpace(portableDefaults.Model) ? "gemma:2b" : portableDefaults.Model.Trim();
            }

            if (normalizedProvider == "openai-codex")
            {
                return IsKnownModelForProvider(normalizedProvider, trimmedCurrent) ? trimmedCurrent : "gpt-5.4-mini";
            }

            if (normalizedProvider == "openrouter")
            {
                return IsKnownModelForProvider(normalizedProvider, trimmedCurrent) ? trimmedCurrent : "openai/gpt-4.1-mini";
            }

            return trimmedCurrent;
        }

        private bool IsKnownLocalModel(string model)
        {
            foreach (string installedModel in GetInstalledLocalModels())
            {
                if (string.Equals(installedModel, model, StringComparison.OrdinalIgnoreCase))
                {
                    return true;
                }
            }

            foreach (string suggestedModel in GetBaseSuggestedLocalModels())
            {
                if (string.Equals(suggestedModel, model, StringComparison.OrdinalIgnoreCase))
                {
                    return true;
                }
            }

            return false;
        }

        private bool IsKnownModelForProvider(string provider, string model)
        {
            if (string.IsNullOrWhiteSpace(model))
            {
                return false;
            }

            foreach (string candidate in GetProviderModels(provider, model))
            {
                if (string.Equals(candidate, model.Trim(), StringComparison.OrdinalIgnoreCase))
                {
                    return true;
                }
            }

            return false;
        }

        private static string NormalizeProvider(string provider)
        {
            return string.IsNullOrWhiteSpace(provider) ? string.Empty : provider.Trim().ToLowerInvariant();
        }

        private void RefreshModelChoices(string currentModel)
        {
            if (isRefreshingModelChoices)
            {
                return;
            }

            string selectedText = string.IsNullOrWhiteSpace(currentModel) ? modelBox.Text.Trim() : currentModel.Trim();
            isRefreshingModelChoices = true;
            try
            {
                modelBox.BeginUpdate();
                try
                {
                    modelBox.Items.Clear();
                    foreach (string model in GetSuggestedModels(providerBox.Text.Trim(), selectedText))
                    {
                        if (!string.IsNullOrWhiteSpace(model) && modelBox.Items.IndexOf(model) < 0)
                        {
                            modelBox.Items.Add(model);
                        }
                    }
                }
                finally
                {
                    modelBox.EndUpdate();
                }

                if (!string.IsNullOrWhiteSpace(selectedText) &&
                    !string.Equals(modelBox.Text, selectedText, StringComparison.Ordinal))
                {
                    modelBox.Text = selectedText;
                }
            }
            finally
            {
                isRefreshingModelChoices = false;
            }
        }

        private void UpdateProviderSpecificUi()
        {
            bool isLocalOllama = NormalizeProvider(providerBox.Text) == "ollama";
            switchModelButton.Enabled = isLocalOllama;
            switchModelButton.Text = isLocalOllama ? "切换本地模型" : "本地模型切换仅适用于 Ollama";
        }

        private string GetPreferredCodexBaseUrl()
        {
            string current = baseUrlBox.Text.Trim();
            if (!string.IsNullOrWhiteSpace(current) &&
                current.IndexOf("/backend-api/codex", StringComparison.OrdinalIgnoreCase) >= 0)
            {
                return current;
            }

            string envOverride = (Environment.GetEnvironmentVariable("HERMES_CODEX_BASE_URL") ?? string.Empty).Trim();
            return string.IsNullOrWhiteSpace(envOverride) ? string.Empty : envOverride;
        }

        internal int RunLauncherSelfTest()
        {
            var report = new List<string>();
            try
            {
                CreateControl();
                PumpUi();

                for (int i = 0; i < presetBox.Items.Count; i++)
                {
                    presetBox.SelectedIndex = i;
                    PumpUi();
                    report.Add(string.Format(
                        "preset={0} provider={1} model={2} baseUrl={3}",
                        presetBox.Text,
                        providerBox.Text,
                        modelBox.Text,
                        baseUrlBox.Text));
                }

                var providers = new[]
                {
                    new ProviderExpectation("ollama", 1, true),
                    new ProviderExpectation("openai-codex", 7, false),
                    new ProviderExpectation("openrouter", 4, false),
                };

                foreach (ProviderExpectation provider in providers)
                {
                    providerBox.Text = provider.Provider;
                    PumpUi();

                    var items = new List<string>();
                    foreach (object item in modelBox.Items)
                    {
                        if (item != null)
                        {
                            items.Add(item.ToString());
                        }
                    }

                    if (items.Count < provider.MinimumItemCount)
                    {
                        throw new InvalidOperationException(string.Format(
                            "provider {0} expected at least {1} items but got {2}",
                            provider.Provider,
                            provider.MinimumItemCount,
                            items.Count));
                    }

                    if (switchModelButton.Enabled != provider.ExpectLocalSwitchEnabled)
                    {
                        throw new InvalidOperationException(string.Format(
                            "provider {0} switch enabled expected {1} but got {2}",
                            provider.Provider,
                            provider.ExpectLocalSwitchEnabled,
                            switchModelButton.Enabled));
                    }

                    report.Add(string.Format(
                        "provider={0} switchEnabled={1} itemCount={2} current={3}",
                        provider.Provider,
                        switchModelButton.Enabled,
                        items.Count,
                        modelBox.Text));

                    for (int i = 0; i < modelBox.Items.Count; i++)
                    {
                        modelBox.SelectedIndex = i;
                        PumpUi();
                        report.Add(string.Format(
                            "select provider={0} idx={1} model={2}",
                            provider.Provider,
                            i,
                            modelBox.Text));
                    }
                }

                string reportPath = WriteSelfTestReport(report, null);
                Console.WriteLine("SELFTEST PASS");
                Console.WriteLine(reportPath);
                return 0;
            }
            catch (Exception ex)
            {
                report.Add("ERROR: " + ex.Message);
                string reportPath = WriteSelfTestReport(report, ex);
                Console.Error.WriteLine("SELFTEST FAIL");
                Console.Error.WriteLine(ex.ToString());
                Console.Error.WriteLine(reportPath);
                return 1;
            }
        }

        private void PumpUi()
        {
            Application.DoEvents();
            System.Threading.Thread.Sleep(80);
            Application.DoEvents();
        }

        private string WriteSelfTestReport(IList<string> lines, Exception ex)
        {
            Directory.CreateDirectory(logsDir);
            string path = Path.Combine(logsDir, "launcher-selftest.log");
            using (var writer = new StreamWriter(path, false, new UTF8Encoding(false)))
            {
                writer.WriteLine("time=" + DateTime.Now.ToString("yyyy-MM-dd HH:mm:ss"));
                writer.WriteLine("appRoot=" + appRoot);
                writer.WriteLine("result=" + (ex == null ? "pass" : "fail"));
                foreach (string line in lines)
                {
                    writer.WriteLine(line);
                }

                if (ex != null)
                {
                    writer.WriteLine("exception=" + ex);
                }
            }

            return path;
        }

        private string ShowLocalModelPicker(string currentModel, IList<LocalModelOption> models)
        {
            using (var dialog = new Form())
            {
                dialog.Text = string.Format("切换本地模型 - 当前: {0}", string.IsNullOrWhiteSpace(currentModel) ? portableDefaults.Model : currentModel);
                dialog.StartPosition = FormStartPosition.CenterParent;
                dialog.FormBorderStyle = FormBorderStyle.FixedDialog;
                dialog.MinimizeBox = false;
                dialog.MaximizeBox = false;
                dialog.ShowInTaskbar = false;
                dialog.ClientSize = new Size(520, 420);

                var info = new Label();
                info.Text = string.Format(
                    "当前默认: {0}    列表模型: {1}    可用直接启动，缺失会在启动时下载到 Go 包内。",
                    string.IsNullOrWhiteSpace(currentModel) ? portableDefaults.Model : currentModel,
                    models.Count);
                info.AutoSize = false;
                info.Location = new Point(12, 12);
                info.Size = new Size(496, 48);

                var listBox = new ListBox();
                listBox.Location = new Point(12, 64);
                listBox.Size = new Size(496, 280);
                listBox.Anchor = AnchorStyles.Top | AnchorStyles.Bottom | AnchorStyles.Left | AnchorStyles.Right;
                listBox.HorizontalScrollbar = true;
                foreach (LocalModelOption model in models)
                {
                    listBox.Items.Add(model);
                }

                int currentIndex = -1;
                for (int i = 0; i < listBox.Items.Count; i++)
                {
                    var item = listBox.Items[i] as LocalModelOption;
                    if (item != null && item.Current)
                    {
                        currentIndex = i;
                        break;
                    }
                }

                if (currentIndex < 0 && listBox.Items.Count > 0)
                {
                    currentIndex = 0;
                }
                if (currentIndex >= 0)
                {
                    listBox.SelectedIndex = currentIndex;
                }

                var selectedInfo = new Label();
                selectedInfo.AutoSize = false;
                selectedInfo.Location = new Point(12, 320);
                selectedInfo.Size = new Size(496, 24);

                var okButton = new Button();
                okButton.Text = "切换";
                okButton.DialogResult = DialogResult.OK;
                okButton.Location = new Point(332, 380);
                okButton.Size = new Size(80, 28);
                okButton.Enabled = false;

                listBox.SelectedIndexChanged += delegate
                {
                    var selected = listBox.SelectedItem as LocalModelOption;
                    if (selected == null)
                    {
                        selectedInfo.Text = string.Empty;
                        okButton.Enabled = false;
                        return;
                    }

                    selectedInfo.Text = string.Format(
                        "状态: {0}  |  模型: {1}",
                        selected.Installed ? "可用" : "缺失，启动时下载到 data\\ollama\\models",
                        selected.Model);
                    okButton.Enabled = true;
                };

                var initialSelected = listBox.SelectedItem as LocalModelOption;
                if (initialSelected != null)
                {
                    selectedInfo.Text = string.Format(
                        "状态: {0}  |  模型: {1}",
                        initialSelected.Installed ? "可用" : "缺失，启动时下载到 data\\ollama\\models",
                        initialSelected.Model);
                    okButton.Enabled = true;
                }

                listBox.DoubleClick += delegate
                {
                    var selected = listBox.SelectedItem as LocalModelOption;
                    if (selected != null)
                    {
                        dialog.DialogResult = DialogResult.OK;
                        dialog.Close();
                    }
                };

                var hint = new Label();
                hint.Text = "缺失模型不会写入系统目录；启动时使用 Go 包内 data\\ollama\\models。";
                hint.AutoSize = false;
                hint.Location = new Point(12, 348);
                hint.Size = new Size(496, 24);

                var cancelButton = new Button();
                cancelButton.Text = "取消";
                cancelButton.DialogResult = DialogResult.Cancel;
                cancelButton.Location = new Point(428, 380);
                cancelButton.Size = new Size(80, 28);

                dialog.AcceptButton = okButton;
                dialog.CancelButton = cancelButton;
                dialog.Controls.Add(info);
                dialog.Controls.Add(listBox);
                dialog.Controls.Add(hint);
                dialog.Controls.Add(selectedInfo);
                dialog.Controls.Add(okButton);
                dialog.Controls.Add(cancelButton);

                if (dialog.ShowDialog(this) == DialogResult.OK && listBox.SelectedItem != null)
                {
                    var selected = listBox.SelectedItem as LocalModelOption;
                    if (selected != null)
                    {
                        return selected.Model;
                    }
                }
            }

            return null;
        }

        private void ApplyLocalModelSelection(string model)
        {
            HermesDefaults current = LoadPortableDefaults();
            string provider = "ollama";
            string baseUrl = portableDefaults.BaseUrl;
            if (string.IsNullOrWhiteSpace(baseUrl))
            {
                baseUrl = string.IsNullOrWhiteSpace(current.BaseUrl) ? "http://127.0.0.1:11434/v1" : current.BaseUrl;
            }

            portableDefaults.Provider = provider;
            portableDefaults.Model = model;
            portableDefaults.BaseUrl = baseUrl;

            providerBox.Text = provider;
            modelBox.Text = model;
            baseUrlBox.Text = baseUrl;

            SavePortableDefaults();
            RefreshModelChoices(model);
            SaveConfigFromForm();
            UpdateLocalPresetLabel(model);
            UpdateSummary();
            AppendLog("已通过 GUI 切换本地模型: " + model);
            SetStatus("本地模型已切换并保存。");
            WriteAutomationSnapshotIfRequested();
        }

        private void WriteAutomationSnapshotIfRequested()
        {
            if (string.IsNullOrWhiteSpace(automationSnapshotPath))
            {
                return;
            }

            if (InvokeRequired)
            {
                BeginInvoke(new Action(WriteAutomationSnapshotIfRequested));
                return;
            }

            try
            {
                string snapshotDir = Path.GetDirectoryName(automationSnapshotPath);
                if (!string.IsNullOrWhiteSpace(snapshotDir))
                {
                    Directory.CreateDirectory(snapshotDir);
                }

                var lines = new List<string>();
                lines.Add("time=" + DateTime.Now.ToString("yyyy-MM-dd HH:mm:ss"));
                lines.Add("window.title=" + EscapeSnapshotValue(Text));
                lines.Add("preset.current=" + EscapeSnapshotValue(presetBox.Text));
                lines.Add("provider.current=" + EscapeSnapshotValue(providerBox.Text));
                lines.Add("model.current=" + EscapeSnapshotValue(modelBox.Text));
                lines.Add("models.ollama=" + JoinSnapshotValues(GetUniqueModelsForProvider("ollama", GetDefaultModelForProvider("ollama", portableDefaults.Model))));
                lines.Add("models.openai-codex=" + JoinSnapshotValues(GetUniqueModelsForProvider("openai-codex", "gpt-5.4-mini")));
                lines.Add("models.openrouter=" + JoinSnapshotValues(GetUniqueModelsForProvider("openrouter", "openai/gpt-4.1-mini")));
                lines.Add("rect.presetBox=" + RectangleToSnapshot(presetBox.RectangleToScreen(presetBox.ClientRectangle)));
                lines.Add("rect.providerBox=" + RectangleToSnapshot(providerBox.RectangleToScreen(providerBox.ClientRectangle)));
                lines.Add("rect.modelBox=" + RectangleToSnapshot(modelBox.RectangleToScreen(modelBox.ClientRectangle)));
                lines.Add("rect.codexButton=" + RectangleToSnapshot(codexButton.RectangleToScreen(codexButton.ClientRectangle)));
                lines.Add("rect.exitButton=" + RectangleToSnapshot(exitButton.RectangleToScreen(exitButton.ClientRectangle)));
                lines.Add("handle.presetBox=" + presetBox.Handle.ToInt64().ToString());
                lines.Add("handle.providerBox=" + providerBox.Handle.ToInt64().ToString());
                lines.Add("handle.modelBox=" + modelBox.Handle.ToInt64().ToString());
                lines.Add("handle.codexButton=" + codexButton.Handle.ToInt64().ToString());
                lines.Add("handle.exitButton=" + exitButton.Handle.ToInt64().ToString());
                File.WriteAllLines(automationSnapshotPath, lines.ToArray(), new UTF8Encoding(false));
            }
            catch (Exception ex)
            {
                SetStatus("自动化快照写入失败: " + ex.Message);
            }
        }

        private List<string> GetUniqueModelsForProvider(string provider, string currentModel)
        {
            var models = new List<string>();
            foreach (string model in GetSuggestedModels(provider, currentModel))
            {
                if (!string.IsNullOrWhiteSpace(model) && !models.Contains(model))
                {
                    models.Add(model);
                }
            }

            return models;
        }

        private static string JoinSnapshotValues(IEnumerable<string> values)
        {
            var output = new List<string>();
            foreach (string value in values)
            {
                if (!string.IsNullOrWhiteSpace(value))
                {
                    output.Add(EscapeSnapshotValue(value));
                }
            }

            return string.Join("|", output.ToArray());
        }

        private static string EscapeSnapshotValue(string value)
        {
            string text = value ?? string.Empty;
            return text.Replace("\\", "\\\\").Replace("|", "\\|");
        }

        private static string RectangleToSnapshot(Rectangle rect)
        {
            return string.Format("{0},{1},{2},{3}", rect.Left, rect.Top, rect.Width, rect.Height);
        }

        private void SavePortableDefaults()
        {
            if (!Directory.Exists(homeDir))
            {
                Directory.CreateDirectory(homeDir);
            }

            string content = string.Join(
                Environment.NewLine,
                new string[]
                {
                    "; Portable fallback defaults for HermesGo",
                    string.Format("DEFAULT_OLLAMA_PROVIDER={0}", portableDefaults.Provider),
                    string.Format("DEFAULT_OLLAMA_MODEL={0}", portableDefaults.Model),
                    string.Format("DEFAULT_OLLAMA_BASE_URL={0}", portableDefaults.BaseUrl),
                    string.Empty
                });

            File.WriteAllText(defaultsPath, content, new UTF8Encoding(false));
        }

        private void UpdateLocalPresetLabel(string model)
        {
            string label = string.Format("本地 Ollama ({0})", model);
            if (presetBox.Items.Count > 1)
            {
                presetBox.Items[1] = label;
            }
        }

        private async Task StartHermesAsync(bool noOpenBrowser, bool noOpenChat)
        {
            if (!File.Exists(startScript))
            {
                MessageBox.Show(this, "找不到 Start-HermesGo.ps1。", "启动失败", MessageBoxButtons.OK, MessageBoxIcon.Error);
                return;
            }

            string args = string.Format(
                "-NoProfile -ExecutionPolicy Bypass -File \"{0}\"{1}{2}",
                startScript,
                noOpenBrowser ? " -NoOpenBrowser" : string.Empty,
                noOpenChat ? " -NoOpenChat" : string.Empty);

            SetStatus("正在启动 HermesGo...");
            AppendLog("启动 HermesGo: powershell " + args);
            await RunProcessAsync("powershell.exe", args, appRoot, null);
            SetStatus("HermesGo 启动命令已执行。");
        }

        private async Task LoginCodexAsync()
        {
            if (!File.Exists(startScript))
            {
                MessageBox.Show(this, "找不到 Start-HermesGo.ps1。", "登录失败", MessageBoxButtons.OK, MessageBoxIcon.Error);
                return;
            }

            string loginUrl = GetCodexDashboardLoginUrl();
            bool suppressDashboardStart = string.Equals(
                Environment.GetEnvironmentVariable("HERMESGO_SUPPRESS_DASHBOARD_START"),
                "1",
                StringComparison.OrdinalIgnoreCase);

            SetStatus("正在启动 Dashboard 并打开 Codex 登录...");
            AppendLog("准备通过 Dashboard 打开 Codex 登录: " + loginUrl);

            if (suppressDashboardStart)
            {
                AppendLog("已抑制 Dashboard 启动，仅验证 Codex 登录入口。");
            }
            else
            {
                await StartHermesAsync(true, true);
            }

            OpenUrl(loginUrl);
            AppendLog("已打开 Codex 登录页: " + loginUrl);
            SetStatus("请在浏览器里完成 Codex 登录或换号。");
        }

        private Task<int> RunProcessAsync(string fileName, string arguments, string workingDirectory, IDictionary<string, string> env)
        {
            var tcs = new TaskCompletionSource<int>();
            var psi = new ProcessStartInfo(fileName, arguments);
            psi.WorkingDirectory = workingDirectory;
            psi.UseShellExecute = false;
            psi.CreateNoWindow = true;
            psi.RedirectStandardOutput = true;
            psi.RedirectStandardError = true;
            psi.StandardOutputEncoding = Encoding.UTF8;
            psi.StandardErrorEncoding = Encoding.UTF8;

            if (env != null)
            {
                foreach (KeyValuePair<string, string> item in env)
                {
                    psi.EnvironmentVariables[item.Key] = item.Value;
                }
            }

            var process = new Process();
            process.StartInfo = psi;
            process.EnableRaisingEvents = true;
            process.OutputDataReceived += (s, e) =>
            {
                if (!string.IsNullOrEmpty(e.Data))
                {
                    AppendLog(e.Data);
                }
            };
            process.ErrorDataReceived += (s, e) =>
            {
                if (!string.IsNullOrEmpty(e.Data))
                {
                    AppendLog("[err] " + e.Data);
                }
            };
            process.Exited += (s, e) =>
            {
                try
                {
                    int exitCode = process.HasExited ? process.ExitCode : -1;
                    tcs.TrySetResult(exitCode);
                }
                catch (Exception ex)
                {
                    tcs.TrySetException(ex);
                }
                finally
                {
                    process.Dispose();
                }
            };

            try
            {
                if (!process.Start())
                {
                    throw new InvalidOperationException("无法启动进程。");
                }
                process.BeginOutputReadLine();
                process.BeginErrorReadLine();
            }
            catch (Exception ex)
            {
                process.Dispose();
                tcs.TrySetException(ex);
            }

            return tcs.Task;
        }

        private void AppendLog(string line)
        {
            if (InvokeRequired)
            {
                BeginInvoke(new Action<string>(AppendLog), line);
                return;
            }

            logBox.AppendText(line + Environment.NewLine);
            logBox.SelectionStart = logBox.TextLength;
            logBox.ScrollToCaret();
        }

        private void SetStatus(string text)
        {
            if (InvokeRequired)
            {
                BeginInvoke(new Action<string>(SetStatus), text);
                return;
            }

            statusLabel.Text = text;
        }

        private void OpenFile(string path)
        {
            if (!File.Exists(path))
            {
                MessageBox.Show(this, "找不到文件: " + path, "无法打开", MessageBoxButtons.OK, MessageBoxIcon.Warning);
                return;
            }

            Process.Start(new ProcessStartInfo(path) { UseShellExecute = true });
        }

        private void OpenFolder(string path)
        {
            if (!Directory.Exists(path))
            {
                MessageBox.Show(this, "找不到目录: " + path, "无法打开", MessageBoxButtons.OK, MessageBoxIcon.Warning);
                return;
            }

            Process.Start(new ProcessStartInfo(path) { UseShellExecute = true });
        }

        private void OpenUrl(string url)
        {
            string openedUrlPath = Environment.GetEnvironmentVariable("HERMESGO_LAST_OPEN_URL_PATH");
            if (!string.IsNullOrWhiteSpace(openedUrlPath))
            {
                try
                {
                    string parentDir = Path.GetDirectoryName(openedUrlPath);
                    if (!string.IsNullOrWhiteSpace(parentDir))
                    {
                        Directory.CreateDirectory(parentDir);
                    }
                    File.WriteAllText(openedUrlPath, url ?? string.Empty, new UTF8Encoding(false));
                }
                catch (Exception ex)
                {
                    AppendLog("记录打开链接失败: " + ex.Message);
                }
            }

            if (string.Equals(Environment.GetEnvironmentVariable("HERMESGO_SUPPRESS_EXTERNAL_OPEN"), "1", StringComparison.OrdinalIgnoreCase))
            {
                AppendLog("已抑制外部打开: " + url);
                return;
            }

            Process.Start(new ProcessStartInfo(url) { UseShellExecute = true });
        }

        private string GetCodexDashboardLoginUrl()
        {
            return dashboardUrl.TrimEnd('/') + "/env?oauth=openai-codex";
        }

    }

    internal sealed class ProviderExpectation
    {
        public ProviderExpectation(string provider, int minimumItemCount, bool expectLocalSwitchEnabled)
        {
            Provider = provider;
            MinimumItemCount = minimumItemCount;
            ExpectLocalSwitchEnabled = expectLocalSwitchEnabled;
        }

        public string Provider { get; private set; }
        public int MinimumItemCount { get; private set; }
        public bool ExpectLocalSwitchEnabled { get; private set; }
    }
}
