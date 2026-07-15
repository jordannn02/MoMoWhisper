using System.Diagnostics;
using MoMoWhisper.Windows.Core;

namespace MoMoWhisper.Windows;

internal sealed class MainForm : Form
{
    private readonly AppPaths _paths = AppPaths.CreateDefault();
    private readonly WhisperRuntime _runtime = WhisperRuntime.FromApplicationDirectory(AppContext.BaseDirectory);
    private readonly MeetingWorkflow _workflow;
    private readonly MeetingHistoryService _history;
    private readonly TextBox _titleBox = new();
    private readonly CheckBox _microphoneCheckBox = new();
    private readonly CheckBox _systemAudioCheckBox = new();
    private readonly Button _recordButton = new();
    private readonly Button _cancelProcessingButton = new();
    private readonly Button _openSessionButton = new();
    private readonly Label _statusLabel = new();
    private readonly Label _runtimeLabel = new();
    private readonly TextBox _transcriptBox = new();
    private readonly ListBox _historyList = new();
    private readonly Button _refreshHistoryButton = new();
    private readonly Button _openHistoryButton = new();
    private bool _busy;
    private CancellationTokenSource? _processingCancellation;
    private string? _latestSessionDirectory;

    public MainForm()
    {
        _paths.EnsureCreated();
        _workflow = new MeetingWorkflow(_paths, _runtime);
        _history = new MeetingHistoryService(_paths);

        Text = "MoMoWhisper Windows Beta";
        StartPosition = FormStartPosition.CenterScreen;
        MinimumSize = new Size(900, 640);
        Size = new Size(1120, 760);
        AutoScaleMode = AutoScaleMode.Dpi;
        Font = new Font("Segoe UI", 10F);

        Controls.Add(BuildLayout());
        ConfigureEvents();
        RefreshRuntimeState();
        RefreshHistory();
    }

    private Control BuildLayout()
    {
        var root = new TableLayoutPanel
        {
            Dock = DockStyle.Fill,
            Padding = new Padding(18),
            ColumnCount = 1,
            RowCount = 4
        };
        root.RowStyles.Add(new RowStyle(SizeType.AutoSize));
        root.RowStyles.Add(new RowStyle(SizeType.AutoSize));
        root.RowStyles.Add(new RowStyle(SizeType.Percent, 100));
        root.RowStyles.Add(new RowStyle(SizeType.AutoSize));

        var heading = new Label
        {
            AutoSize = true,
            Font = new Font("Segoe UI Semibold", 19F, FontStyle.Bold),
            Text = "MoMoWhisper Windows Beta"
        };
        var boundary = new Label
        {
            AutoSize = true,
            ForeColor = Color.DarkOrange,
            Padding = new Padding(0, 4, 0, 12),
            Text = "停止錄音後才轉錄 · MIC / SYS 分開處理 · 非 macOS 功能等價版"
        };
        var headingPanel = new FlowLayoutPanel
        {
            AutoSize = true,
            Dock = DockStyle.Fill,
            FlowDirection = FlowDirection.TopDown,
            WrapContents = false
        };
        headingPanel.Controls.Add(heading);
        headingPanel.Controls.Add(boundary);
        root.Controls.Add(headingPanel, 0, 0);

        var controls = new TableLayoutPanel
        {
            AutoSize = true,
            Dock = DockStyle.Fill,
            ColumnCount = 7,
            Padding = new Padding(0, 0, 0, 12)
        };
        controls.ColumnStyles.Add(new ColumnStyle(SizeType.AutoSize));
        controls.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100));
        controls.ColumnStyles.Add(new ColumnStyle(SizeType.AutoSize));
        controls.ColumnStyles.Add(new ColumnStyle(SizeType.AutoSize));
        controls.ColumnStyles.Add(new ColumnStyle(SizeType.AutoSize));
        controls.ColumnStyles.Add(new ColumnStyle(SizeType.AutoSize));
        controls.ColumnStyles.Add(new ColumnStyle(SizeType.AutoSize));

        controls.Controls.Add(new Label
        {
            AutoSize = true,
            Anchor = AnchorStyles.Left,
            Text = "會議名稱"
        }, 0, 0);
        _titleBox.Dock = DockStyle.Fill;
        _titleBox.PlaceholderText = "例如：客戶需求討論";
        controls.Controls.Add(_titleBox, 1, 0);

        _microphoneCheckBox.AutoSize = true;
        _microphoneCheckBox.Checked = true;
        _microphoneCheckBox.Text = "麥克風 [MIC]";
        controls.Controls.Add(_microphoneCheckBox, 2, 0);

        _systemAudioCheckBox.AutoSize = true;
        _systemAudioCheckBox.Checked = true;
        _systemAudioCheckBox.Text = "系統音訊 [SYS]";
        controls.Controls.Add(_systemAudioCheckBox, 3, 0);

        _recordButton.AutoSize = true;
        _recordButton.Padding = new Padding(12, 4, 12, 4);
        _recordButton.Text = "開始錄音";
        controls.Controls.Add(_recordButton, 4, 0);

        _cancelProcessingButton.AutoSize = true;
        _cancelProcessingButton.Enabled = false;
        _cancelProcessingButton.Text = "取消轉錄";
        controls.Controls.Add(_cancelProcessingButton, 5, 0);

        _openSessionButton.AutoSize = true;
        _openSessionButton.Enabled = false;
        _openSessionButton.Text = "開啟本次資料夾";
        controls.Controls.Add(_openSessionButton, 6, 0);
        root.Controls.Add(controls, 0, 1);

        var tabs = new TabControl { Dock = DockStyle.Fill };
        tabs.TabPages.Add(BuildTranscriptTab());
        tabs.TabPages.Add(BuildHistoryTab());
        root.Controls.Add(tabs, 0, 2);

        var footer = new TableLayoutPanel
        {
            AutoSize = true,
            Dock = DockStyle.Fill,
            ColumnCount = 1,
            Padding = new Padding(0, 10, 0, 0)
        };
        _statusLabel.AutoSize = true;
        _statusLabel.Text = "Ready";
        _runtimeLabel.AutoSize = true;
        _runtimeLabel.ForeColor = Color.DimGray;
        footer.Controls.Add(_statusLabel, 0, 0);
        footer.Controls.Add(_runtimeLabel, 0, 1);
        root.Controls.Add(footer, 0, 3);
        return root;
    }

    private TabPage BuildTranscriptTab()
    {
        var page = new TabPage("逐字稿 / 狀態");
        _transcriptBox.Dock = DockStyle.Fill;
        _transcriptBox.Multiline = true;
        _transcriptBox.ReadOnly = true;
        _transcriptBox.ScrollBars = ScrollBars.Both;
        _transcriptBox.WordWrap = false;
        _transcriptBox.Font = new Font("Consolas", 10F);
        _transcriptBox.Text =
            "Windows Beta 會先錄製兩個獨立 WAV。按停止後，才依序執行 whisper.cpp 並產生 [MIC] / [SYS] 逐字稿。";
        page.Controls.Add(_transcriptBox);
        return page;
    }

    private TabPage BuildHistoryTab()
    {
        var page = new TabPage("歷史");
        var layout = new TableLayoutPanel
        {
            Dock = DockStyle.Fill,
            ColumnCount = 1,
            RowCount = 2,
            Padding = new Padding(8)
        };
        layout.RowStyles.Add(new RowStyle(SizeType.Percent, 100));
        layout.RowStyles.Add(new RowStyle(SizeType.AutoSize));
        _historyList.Dock = DockStyle.Fill;
        _historyList.HorizontalScrollbar = true;
        layout.Controls.Add(_historyList, 0, 0);

        var buttons = new FlowLayoutPanel
        {
            AutoSize = true,
            FlowDirection = FlowDirection.LeftToRight,
            Padding = new Padding(0, 8, 0, 0)
        };
        _refreshHistoryButton.AutoSize = true;
        _refreshHistoryButton.Text = "重新整理";
        _openHistoryButton.AutoSize = true;
        _openHistoryButton.Text = "開啟所選資料夾";
        buttons.Controls.Add(_refreshHistoryButton);
        buttons.Controls.Add(_openHistoryButton);
        layout.Controls.Add(buttons, 0, 1);
        page.Controls.Add(layout);
        return page;
    }

    private void ConfigureEvents()
    {
        _recordButton.Click += async (_, _) => await ToggleRecordingAsync();
        _cancelProcessingButton.Click += (_, _) => CancelPostStopProcessing();
        _openSessionButton.Click += (_, _) => OpenFolder(_latestSessionDirectory);
        _refreshHistoryButton.Click += (_, _) => RefreshHistory();
        _openHistoryButton.Click += (_, _) => OpenSelectedHistoryFolder();
        _historyList.DoubleClick += (_, _) => OpenSelectedHistoryFolder();
        FormClosing += OnFormClosing;
    }

    private async Task ToggleRecordingAsync()
    {
        if (_busy)
        {
            return;
        }

        if (!_workflow.IsRecording)
        {
            StartRecording();
            return;
        }

        await StopRecordingAsync();
    }

    private void StartRecording()
    {
        if (!_microphoneCheckBox.Checked && !_systemAudioCheckBox.Checked)
        {
            MessageBox.Show(
                this,
                "請至少選擇麥克風或系統音訊。",
                "MoMoWhisper Windows Beta",
                MessageBoxButtons.OK,
                MessageBoxIcon.Warning);
            return;
        }

        try
        {
            var session = _workflow.Start(
                _titleBox.Text,
                _microphoneCheckBox.Checked,
                _systemAudioCheckBox.Checked);
            _latestSessionDirectory = session.SessionDirectory;
            _recordButton.Text = "停止並轉錄";
            _titleBox.Enabled = false;
            _microphoneCheckBox.Enabled = false;
            _systemAudioCheckBox.Enabled = false;
            _openSessionButton.Enabled = true;
            _statusLabel.Text = "Recording separate MIC/SYS streams...";
            _transcriptBox.Text =
                $"錄音中：{session.Title}{Environment.NewLine}" +
                "按「停止並轉錄」後才會執行本機 whisper.cpp。";
        }
        catch (Exception error)
        {
            ShowError("錄音無法開始", error);
            RefreshHistory();
        }
    }

    private async Task StopRecordingAsync()
    {
        _processingCancellation?.Dispose();
        var processingCancellation = new CancellationTokenSource();
        _processingCancellation = processingCancellation;
        SetBusy(true);
        var progress = new Progress<string>(message => _statusLabel.Text = message);
        try
        {
            var result = await _workflow.StopAndTranscribeAsync(
                progress,
                processingCancellation.Token);
            _latestSessionDirectory = result.Metadata.SessionDirectory;
            _transcriptBox.Text = result.Artifacts.TranscriptMarkdown;
            if (result.Metadata.Warnings.Count > 0)
            {
                _transcriptBox.AppendText(
                    Environment.NewLine +
                    Environment.NewLine +
                    "Warnings:" +
                    Environment.NewLine +
                    string.Join(Environment.NewLine, result.Metadata.Warnings.Select(item => $"- {item}")));
            }

            RefreshHistory();
        }
        catch (OperationCanceledException)
        {
            _statusLabel.Text =
                "Post-stop processing cancelled. Audio/metadata were kept; latest_valid was not replaced.";
            var transcriptPath = _latestSessionDirectory is null
                ? null
                : Path.Combine(_latestSessionDirectory, "transcript.md");
            if (transcriptPath is not null && File.Exists(transcriptPath))
            {
                _transcriptBox.Text = File.ReadAllText(transcriptPath);
            }

            RefreshHistory();
        }
        catch (Exception error)
        {
            ShowError("停止或轉錄失敗", error);
        }
        finally
        {
            processingCancellation.Dispose();
            if (ReferenceEquals(_processingCancellation, processingCancellation))
            {
                _processingCancellation = null;
            }
            SetBusy(false);
            _recordButton.Text = "開始新會議";
            _titleBox.Enabled = true;
            _microphoneCheckBox.Enabled = true;
            _systemAudioCheckBox.Enabled = true;
            _openSessionButton.Enabled = _latestSessionDirectory is not null;
        }
    }

    private void CancelPostStopProcessing()
    {
        if (_processingCancellation is null || _processingCancellation.IsCancellationRequested)
        {
            return;
        }

        _processingCancellation.Cancel();
        _cancelProcessingButton.Enabled = false;
        _statusLabel.Text = "Cancellation requested; finishing audio writers safely...";
    }

    private void SetBusy(bool busy)
    {
        _busy = busy;
        _recordButton.Enabled = !busy;
        _cancelProcessingButton.Enabled = busy;
        _refreshHistoryButton.Enabled = !busy;
        _openHistoryButton.Enabled = !busy;
        UseWaitCursor = busy;
    }

    private void RefreshRuntimeState()
    {
        _runtimeLabel.Text = $"Runtime: {_runtime.AvailabilityText}";
        _runtimeLabel.ForeColor = _runtime.IsAvailable ? Color.DarkGreen : Color.Firebrick;
    }

    private void RefreshHistory()
    {
        var selectedId = (_historyList.SelectedItem as HistoryListItem)?.Metadata.SessionId;
        _historyList.BeginUpdate();
        _historyList.Items.Clear();
        foreach (var metadata in _history.ListSessions())
        {
            var item = new HistoryListItem(metadata);
            _historyList.Items.Add(item);
            if (metadata.SessionId == selectedId)
            {
                _historyList.SelectedItem = item;
            }
        }

        _historyList.EndUpdate();
    }

    private void OpenSelectedHistoryFolder()
    {
        OpenFolder((_historyList.SelectedItem as HistoryListItem)?.Metadata.SessionDirectory);
    }

    private static void OpenFolder(string? path)
    {
        if (path is null || !Directory.Exists(path))
        {
            return;
        }

        Process.Start(new ProcessStartInfo
        {
            FileName = path,
            UseShellExecute = true
        });
    }

    private void OnFormClosing(object? sender, FormClosingEventArgs eventArgs)
    {
        if (_workflow.IsRecording || _busy)
        {
            MessageBox.Show(
                this,
                "請先停止錄音並等待轉錄完成，再關閉 Windows Beta。",
                "MoMoWhisper Windows Beta",
                MessageBoxButtons.OK,
                MessageBoxIcon.Warning);
            eventArgs.Cancel = true;
            return;
        }

        _workflow.Dispose();
        _processingCancellation?.Dispose();
    }

    private void ShowError(string title, Exception error)
    {
        _statusLabel.Text = $"{title}: {error.Message}";
        MessageBox.Show(
            this,
            error.Message,
            title,
            MessageBoxButtons.OK,
            MessageBoxIcon.Error);
    }

    private sealed record HistoryListItem(MeetingSessionMetadata Metadata)
    {
        public override string ToString() =>
            $"{Metadata.StartedAt:yyyy-MM-dd HH:mm:ss}  |  {Metadata.Status,-24}  |  {Metadata.Title}";
    }
}
