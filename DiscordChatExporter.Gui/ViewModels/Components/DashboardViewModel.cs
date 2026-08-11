using System;
using System.Collections.Generic;
using System.Collections.ObjectModel;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Threading;
using System.Threading.Tasks;
using CommunityToolkit.Mvvm.ComponentModel;
using CommunityToolkit.Mvvm.Input;
using DiscordChatExporter.Core.Discord;
using DiscordChatExporter.Core.Discord.Data;
using DiscordChatExporter.Core.Exceptions;
using DiscordChatExporter.Core.Exporting;
using DiscordChatExporter.Gui.Framework;
using DiscordChatExporter.Gui.Localization;
using DiscordChatExporter.Gui.Models;
using DiscordChatExporter.Gui.Services;
using Gress;
using Gress.Completable;
using PowerKit;
using PowerKit.Extensions;

namespace DiscordChatExporter.Gui.ViewModels.Components;

public partial class DashboardViewModel : ViewModelBase
{
    private readonly ViewModelManager _viewModelManager;
    private readonly SnackbarManager _snackbarManager;
    private readonly DialogManager _dialogManager;
    private readonly SettingsService _settingsService;

    private readonly IDisposable _eventSubscription;
    private readonly AutoResetProgressMuxer _progressMuxer;

    private DiscordClient? _discord;

    public DashboardViewModel(
        ViewModelManager viewModelManager,
        DialogManager dialogManager,
        SnackbarManager snackbarManager,
        SettingsService settingsService,
        LocalizationManager localizationManager
    )
    {
        _viewModelManager = viewModelManager;
        _dialogManager = dialogManager;
        _snackbarManager = snackbarManager;
        _settingsService = settingsService;
        LocalizationManager = localizationManager;

        _progressMuxer = Progress.CreateMuxer().WithAutoReset();

        _eventSubscription = Disposable.Merge(
            Progress.WatchProperty(
                o => o.Current,
                _ => OnPropertyChanged(nameof(IsProgressIndeterminate))
            ),
            SelectedChannels.WatchProperty(
                o => o.Count,
                _ => ExportCommand.NotifyCanExecuteChanged()
            )
        );
    }

    [ObservableProperty]
    [NotifyPropertyChangedFor(nameof(IsProgressIndeterminate))]
    [NotifyCanExecuteChangedFor(nameof(PullGuildsCommand))]
    [NotifyCanExecuteChangedFor(nameof(PullChannelsCommand))]
    [NotifyCanExecuteChangedFor(nameof(ExportCommand))]
    [NotifyCanExecuteChangedFor(nameof(ExportEntireServerCommand))]
    public partial bool IsBusy { get; set; }

    public LocalizationManager LocalizationManager { get; }

    public ProgressContainer<Percentage> Progress { get; } = new();

    public bool IsProgressIndeterminate => IsBusy && Progress.Current.Fraction is <= 0 or >= 1;

    [ObservableProperty]
    [NotifyCanExecuteChangedFor(nameof(PullGuildsCommand))]
    public partial string? Token { get; set; }

    [ObservableProperty]
    public partial IReadOnlyList<Guild>? AvailableGuilds { get; set; }

    [ObservableProperty]
    [NotifyCanExecuteChangedFor(nameof(PullChannelsCommand))]
    [NotifyCanExecuteChangedFor(nameof(ExportCommand))]
    [NotifyCanExecuteChangedFor(nameof(ExportEntireServerCommand))]
    public partial Guild? SelectedGuild { get; set; }

    [ObservableProperty]
    [NotifyCanExecuteChangedFor(nameof(ExportEntireServerCommand))]
    public partial IReadOnlyList<ChannelConnection>? AvailableChannels { get; set; }

    public ObservableCollection<ChannelConnection> SelectedChannels { get; } = [];

    public override Task InitializeAsync()
    {
        if (!string.IsNullOrWhiteSpace(_settingsService.LastToken))
            Token = _settingsService.LastToken;

        return Task.CompletedTask;
    }

    [RelayCommand]
    private async Task ShowSettingsAsync() =>
        await _dialogManager.ShowDialogAsync(_viewModelManager.GetSettingsViewModel());

    // Scan a folder of existing exports and build categorized link lists
    // (file-host / video / webpage) plus a JDownloader crawljob, by running the
    // bundled Extract-DiscordLinks.ps1 helper.
    [RelayCommand]
    private async Task ExtractLinksAsync()
    {
        var folder = await _dialogManager.PromptDirectoryPathAsync();
        if (string.IsNullOrWhiteSpace(folder))
            return;

        if (!OperatingSystem.IsWindows())
        {
            _snackbarManager.Notify(
                "Link extraction runs on Windows. Run backup/scripts/Extract-DiscordLinks.ps1 manually."
            );
            return;
        }

        var script = Path.Combine(AppContext.BaseDirectory, "Tools", "Extract-DiscordLinks.ps1");
        if (!File.Exists(script))
        {
            _snackbarManager.Notify("Could not find the link extractor (Tools/Extract-DiscordLinks.ps1).");
            return;
        }

        try
        {
            var startInfo = new ProcessStartInfo
            {
                FileName = "powershell.exe",
                UseShellExecute = true,
            };
            startInfo.ArgumentList.Add("-NoProfile");
            startInfo.ArgumentList.Add("-ExecutionPolicy");
            startInfo.ArgumentList.Add("Bypass");
            startInfo.ArgumentList.Add("-NoExit");
            startInfo.ArgumentList.Add("-File");
            startInfo.ArgumentList.Add(script);
            startInfo.ArgumentList.Add("-Root");
            startInfo.ArgumentList.Add(folder);
            startInfo.ArgumentList.Add("-Crawljob");

            Process.Start(startInfo);

            _snackbarManager.Notify(
                "Extracting links - see the PowerShell window. Lists are written to the folder's _LINKS subfolder."
            );
        }
        catch (Exception ex)
        {
            _snackbarManager.Notify(ex.Message.TrimEnd('.'));
        }
    }

    private bool CanPullGuilds() => !IsBusy && !string.IsNullOrWhiteSpace(Token);

    [RelayCommand(CanExecute = nameof(CanPullGuilds))]
    private async Task PullGuildsAsync()
    {
        IsBusy = true;
        var progress = _progressMuxer.CreateInput();

        try
        {
            var token = Token?.Trim('"', ' ');
            if (string.IsNullOrWhiteSpace(token))
                return;

            AvailableGuilds = null;
            SelectedGuild = null;
            AvailableChannels = null;
            SelectedChannels.Clear();

            _discord = new DiscordClient(
                token,
                _settingsService.RateLimitPreference,
                _settingsService.RequestDelayMs > 0
                    ? System.TimeSpan.FromMilliseconds(_settingsService.RequestDelayMs)
                    : null
            );
            _settingsService.LastToken = token;

            var guilds = await _discord.GetUserGuildsAsync();

            AvailableGuilds = guilds;
            SelectedGuild = guilds.FirstOrDefault();

            await PullChannelsAsync();
        }
        catch (DiscordChatExporterException ex) when (!ex.IsFatal)
        {
            _snackbarManager.Notify(ex.Message.TrimEnd('.'));
        }
        catch (Exception ex)
        {
            var dialog = _viewModelManager.GetMessageBoxViewModel(
                LocalizationManager.ErrorPullingGuildsTitle,
                ex.ToString()
            );

            await _dialogManager.ShowDialogAsync(dialog);
        }
        finally
        {
            progress.ReportCompletion();
            IsBusy = false;
        }
    }

    private bool CanPullChannels() => !IsBusy && _discord is not null && SelectedGuild is not null;

    [RelayCommand(CanExecute = nameof(CanPullChannels))]
    private async Task PullChannelsAsync()
    {
        IsBusy = true;
        var progress = _progressMuxer.CreateInput();

        try
        {
            if (_discord is null || SelectedGuild is null)
                return;

            AvailableChannels = null;
            SelectedChannels.Clear();

            var channels = new List<Channel>();

            // Regular channels
            await foreach (var channel in _discord.GetGuildChannelsAsync(SelectedGuild.Id))
                channels.Add(channel);

            // Threads
            if (_settingsService.ThreadInclusionMode != ThreadInclusionMode.None)
            {
                await foreach (
                    var thread in _discord.GetGuildThreadsAsync(
                        SelectedGuild.Id,
                        _settingsService.ThreadInclusionMode == ThreadInclusionMode.All
                    )
                )
                {
                    channels.Add(thread);
                }
            }

            // Build a hierarchy of channels
            var channelTree = ChannelConnection.BuildTree(
                channels
                    .OrderByDescending(c => c.IsDirect ? c.LastMessageId : null)
                    .ThenBy(c => c.Position)
                    .ToArray()
            );

            AvailableChannels = channelTree;
            SelectedChannels.Clear();
        }
        catch (DiscordChatExporterException ex) when (!ex.IsFatal)
        {
            _snackbarManager.Notify(ex.Message.TrimEnd('.'));
        }
        catch (Exception ex)
        {
            var dialog = _viewModelManager.GetMessageBoxViewModel(
                LocalizationManager.ErrorPullingChannelsTitle,
                ex.ToString()
            );

            await _dialogManager.ShowDialogAsync(dialog);
        }
        finally
        {
            progress.ReportCompletion();
            IsBusy = false;
        }
    }

    private bool CanExport() =>
        !IsBusy && _discord is not null && SelectedGuild is not null && SelectedChannels.Any();

    [RelayCommand(CanExecute = nameof(CanExport))]
    private async Task ExportAsync() =>
        await RunExportAsync(
            SelectedChannels.Select(c => c.Channel).ToArray(),
            organizeIntoFolders: false
        );

    private bool CanExportEntireServer() =>
        !IsBusy
        && _discord is not null
        && SelectedGuild is not null
        && AvailableChannels is { Count: > 0 };

    [RelayCommand(CanExecute = nameof(CanExportEntireServer))]
    private async Task ExportEntireServerAsync()
    {
        if (AvailableChannels is null)
            return;

        // Flatten the channel tree into every exportable (non-category) channel
        var channels = new List<Channel>();

        void Collect(IReadOnlyList<ChannelConnection> nodes)
        {
            foreach (var node in nodes)
            {
                if (!node.Channel.IsCategory)
                    channels.Add(node.Channel);

                Collect(node.Children);
            }
        }

        Collect(AvailableChannels);

        if (channels.Count == 0)
        {
            _snackbarManager.Notify("This server has no exportable channels");
            return;
        }

        await RunExportAsync(channels, organizeIntoFolders: true);
    }

    private async Task RunExportAsync(
        IReadOnlyList<Channel> channels,
        bool organizeIntoFolders
    )
    {
        IsBusy = true;

        try
        {
            if (_discord is null || SelectedGuild is null || channels.Count == 0)
                return;

            var dialog = _viewModelManager.GetExportSetupViewModel(SelectedGuild, channels);

            if (await _dialogManager.ShowDialogAsync(dialog) != true)
                return;

            var exporter = new ChannelExporter(_discord);

            // When exporting a whole server, expand the chosen directory into a
            // Server/Category/Channel folder tree so the structure is preserved on disk.
            // (A plain directory would otherwise dump every channel into one flat folder.)
            var outputPath = dialog.OutputPath!;
            if (organizeIntoFolders && !outputPath.Contains('%'))
            {
                var extension = dialog.SelectedFormat.GetFileExtension();
                outputPath =
                    outputPath.TrimEnd(
                        Path.DirectorySeparatorChar,
                        Path.AltDirectorySeparatorChar
                    )
                    + Path.DirectorySeparatorChar
                    + "%G"
                    + Path.DirectorySeparatorChar
                    + "%T"
                    + Path.DirectorySeparatorChar
                    + "%C [%c]."
                    + extension;
            }

            var channelProgressPairs = dialog
                .Channels!.Select(c => new { Channel = c, Progress = _progressMuxer.CreateInput() })
                .ToArray();

            var successfulExportCount = 0;

            await Parallel.ForEachAsync(
                channelProgressPairs,
                new ParallelOptions
                {
                    MaxDegreeOfParallelism = Math.Max(1, _settingsService.ParallelLimit),
                },
                async (pair, cancellationToken) =>
                {
                    var channel = pair.Channel;
                    var progress = pair.Progress;

                    try
                    {
                        var request = new ExportRequest(
                            dialog.Guild!,
                            channel,
                            outputPath,
                            dialog.AssetsDirPath,
                            dialog.SelectedFormat,
                            dialog.After?.Pipe(Snowflake.FromDate),
                            dialog.Before?.Pipe(Snowflake.FromDate),
                            dialog.PartitionLimit,
                            dialog.MessageFilter,
                            dialog.IsReverseMessageOrder,
                            dialog.ShouldFormatMarkdown,
                            dialog.ShouldDownloadAssets,
                            dialog.ShouldReuseAssets,
                            _settingsService.Locale,
                            _settingsService.IsUtcNormalizationEnabled
                        );

                        await exporter.ExportChannelAsync(request, progress, cancellationToken);

                        Interlocked.Increment(ref successfulExportCount);
                    }
                    catch (ChannelEmptyException ex)
                    {
                        _snackbarManager.Notify(ex.Message.TrimEnd('.'));
                    }
                    catch (DiscordChatExporterException ex) when (!ex.IsFatal)
                    {
                        _snackbarManager.Notify(ex.Message.TrimEnd('.'));
                    }
                    finally
                    {
                        progress.ReportCompletion();
                    }
                }
            );

            // Notify of the overall completion
            if (successfulExportCount > 0)
            {
                _snackbarManager.Notify(
                    string.Format(
                        LocalizationManager.SuccessfulExportMessage,
                        successfulExportCount
                    )
                );
            }
        }
        catch (Exception ex)
        {
            var dialog = _viewModelManager.GetMessageBoxViewModel(
                LocalizationManager.ErrorExportingTitle,
                ex.ToString()
            );

            await _dialogManager.ShowDialogAsync(dialog);
        }
        finally
        {
            IsBusy = false;
        }
    }

    protected override void Dispose(bool disposing)
    {
        if (disposing)
        {
            _eventSubscription.Dispose();
        }

        base.Dispose(disposing);
    }
}
