[CmdletBinding()]
param(
  [ValidatePattern('^[a-z0-9](?:[a-z0-9-]{0,30}[a-z0-9])?$')]
  [string]$ProfileId = "workstation",

  [switch]$ValidateOnly,

  [switch]$Preview
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version 3.0

if ($env:OS -cne "Windows_NT") {
  throw "Hybrid MCP Control Center currently supports Windows only."
}
if ($ValidateOnly -and $Preview) {
  throw "ValidateOnly and Preview cannot be used together."
}

Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName PresentationCore
Add-Type -AssemblyName WindowsBase

$script:InstanceMutex = $null
if (-not $ValidateOnly -and -not $Preview) {
  $CreatedNew = $false
  $InstanceMutex = [Threading.Mutex]::new(
    $true,
    "Local\HybridWorkstationMcp-ControlCenter",
    [ref]$CreatedNew
  )
  if (-not $CreatedNew) {
    $null = [Windows.MessageBox]::Show(
      "Hybrid MCP Control Center is already open.",
      "Hybrid MCP Control Center",
      [Windows.MessageBoxButton]::OK,
      [Windows.MessageBoxImage]::Information
    )
    $InstanceMutex.Dispose()
    return
  }
  $script:InstanceMutex = $InstanceMutex
}

$ToolRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot "..") -ErrorAction Stop).Path
$PowerShellPath = Join-Path $env:SystemRoot "System32\WindowsPowerShell\v1.0\powershell.exe"
$StatusScript = Join-Path $PSScriptRoot "tunnel-status.ps1"
$StartScript = Join-Path $PSScriptRoot "start-tunnel.ps1"
$StopScript = Join-Path $PSScriptRoot "stop-tunnel.ps1"
$ControlScript = Join-Path $PSScriptRoot "Control.ps1"
$ManagerScript = Join-Path $PSScriptRoot "tunnel-manager.ps1"
$DoctorScript = Join-Path $PSScriptRoot "Doctor.ps1"
$ConfigureScript = Join-Path $PSScriptRoot "Configure-Tunnel.ps1"

foreach ($RequiredPath in @(
  $PowerShellPath,
  $StatusScript,
  $StartScript,
  $StopScript,
  $ControlScript,
  $ManagerScript,
  $DoctorScript,
  $ConfigureScript
)) {
  if (-not (Test-Path -LiteralPath $RequiredPath -PathType Leaf)) {
    throw "Control Center dependency is missing: $RequiredPath"
  }
}

function Test-ControlCenterReadyValue([object]$Value) {
  if ($null -eq $Value) { return $false }
  if ($Value -is [string]) { return [string]$Value -ceq "ready" }
  $StatusProperty = $Value.PSObject.Properties["status"]
  if ($null -ne $StatusProperty) { return [string]$StatusProperty.Value -ceq "ready" }
  $ReadyProperty = $Value.PSObject.Properties["ready"]
  if ($null -ne $ReadyProperty) { return [bool]$ReadyProperty.Value }
  return $false
}

function Test-ControlCenterManagedStatusActive([object]$Status) {
  if ($null -eq $Status) { return $false }
  if ([bool]$Status.running -or [bool]$Status.supervised) { return $true }
  if (-not [bool]$Status.desiredRunning -or [bool]$Status.stopRequested) { return $false }
  return [string]$Status.recoveryState -in @("starting", "backoff", "recovering", "restarting", "ready")
}

function Get-ControlCenterPresentation {
  param(
    [object]$Status,
    [string]$StatusError
  )

  if (-not [string]::IsNullOrWhiteSpace($StatusError) -or $null -eq $Status) {
    return [pscustomobject]@{
      state = "issue"
      badge = "CHECK NEEDED"
      title = "Connection needs attention"
      description = "Run a quick check to find out what needs fixing."
      primaryAction = "doctor"
      primaryText = "Run connection check"
      accent = "#FFB454"
      issueVisible = $true
      issueText = "The local connection status could not be verified. Your credentials are never shown here."
    }
  }

  $Ready = [bool]$Status.running -and (Test-ControlCenterReadyValue $Status.ready)
  if ($Ready) {
    return [pscustomobject]@{
      state = "connected"
      badge = "CONNECTED"
      title = "ChatGPT is connected"
      description = "This computer is available through your secure MCP tunnel."
      primaryAction = "stop"
      primaryText = "Disconnect"
      accent = "#56D6A6"
      issueVisible = $false
      issueText = ""
    }
  }

  $HasRunIntent = [bool]$Status.desiredRunning -or [bool]$Status.supervised -or [bool]$Status.running
  if ($HasRunIntent) {
    $RecoveryState = [string]$Status.recoveryState
    $Recovering = $RecoveryState -in @("starting", "backoff", "recovering", "restarting") -or
      ([bool]$Status.desiredRunning -and -not [bool]$Status.stopRequested)
    if ($Recovering) {
      $DelayText = if ($null -ne $Status.recoveryNextDelaySeconds -and [int]$Status.recoveryNextDelaySeconds -gt 0) {
        " The next attempt starts in $([int]$Status.recoveryNextDelaySeconds) seconds."
      } else { "" }
      return [pscustomobject]@{
        state = "recovering"
        badge = "RECONNECTING"
        title = "Reconnecting securely"
        description = "The connection is recovering automatically.$DelayText"
        primaryAction = "stop"
        primaryText = "Stop reconnecting"
        accent = "#FFB454"
        issueVisible = $false
        issueText = ""
      }
    }

    return [pscustomobject]@{
      state = "issue"
      badge = "CHECK NEEDED"
      title = "Connection needs attention"
      description = "The tunnel started but did not become ready."
      primaryAction = "doctor"
      primaryText = "Run connection check"
      accent = "#FF6B7A"
      issueVisible = $true
      issueText = "A previous connection may have ended unexpectedly. Run a check, then reconnect."
    }
  }

  return [pscustomobject]@{
    state = "stopped"
    badge = "NOT CONNECTED"
    title = "Ready when you are"
    description = "Connect only when you want ChatGPT to use this computer."
    primaryAction = "start"
    primaryText = "Connect to ChatGPT"
    accent = "#8B7CFF"
    issueVisible = $false
    issueText = ""
  }
}

$Xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Hybrid MCP Control Center"
        Width="820" Height="620" MinWidth="720" MinHeight="600"
        WindowStartupLocation="CenterScreen" WindowStyle="None"
        ResizeMode="CanResizeWithGrip" AllowsTransparency="True"
        Background="Transparent" FontFamily="Segoe UI"
        TextOptions.TextFormattingMode="Display" UseLayoutRounding="True">
  <Window.Resources>
    <SolidColorBrush x:Key="WindowBackground" Color="#0B1020" />
    <SolidColorBrush x:Key="CardBackground" Color="#141B2C" />
    <SolidColorBrush x:Key="CardBorder" Color="#263149" />
    <SolidColorBrush x:Key="TextPrimary" Color="#F5F7FF" />
    <SolidColorBrush x:Key="TextSecondary" Color="#A8B2C7" />
    <SolidColorBrush x:Key="Accent" Color="#8B7CFF" />
    <SolidColorBrush x:Key="AccentHover" Color="#9C90FF" />
    <SolidColorBrush x:Key="SecondaryButton" Color="#1C263B" />
    <SolidColorBrush x:Key="SecondaryButtonHover" Color="#26334D" />

    <Style x:Key="WindowButtonStyle" TargetType="Button">
      <Setter Property="Width" Value="38" />
      <Setter Property="Height" Value="34" />
      <Setter Property="Margin" Value="4,0,0,0" />
      <Setter Property="Foreground" Value="{StaticResource TextSecondary}" />
      <Setter Property="Background" Value="Transparent" />
      <Setter Property="BorderThickness" Value="0" />
      <Setter Property="FontSize" Value="15" />
      <Setter Property="Cursor" Value="Hand" />
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="ButtonBorder" Background="{TemplateBinding Background}" CornerRadius="9">
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center" />
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="ButtonBorder" Property="Background" Value="#222D44" />
                <Setter Property="Foreground" Value="#FFFFFF" />
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <Style x:Key="PrimaryButtonStyle" TargetType="Button">
      <Setter Property="Height" Value="54" />
      <Setter Property="Padding" Value="28,0" />
      <Setter Property="Foreground" Value="White" />
      <Setter Property="Background" Value="{StaticResource Accent}" />
      <Setter Property="BorderThickness" Value="0" />
      <Setter Property="FontSize" Value="15" />
      <Setter Property="FontWeight" Value="SemiBold" />
      <Setter Property="Cursor" Value="Hand" />
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="ButtonBorder" Background="{TemplateBinding Background}" CornerRadius="14">
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center" />
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="ButtonBorder" Property="Background" Value="{StaticResource AccentHover}" />
              </Trigger>
              <Trigger Property="IsPressed" Value="True">
                <Setter TargetName="ButtonBorder" Property="Opacity" Value="0.82" />
              </Trigger>
              <Trigger Property="IsEnabled" Value="False">
                <Setter TargetName="ButtonBorder" Property="Opacity" Value="0.42" />
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <Style x:Key="SecondaryButtonStyle" TargetType="Button">
      <Setter Property="Height" Value="42" />
      <Setter Property="Padding" Value="16,0" />
      <Setter Property="Foreground" Value="{StaticResource TextPrimary}" />
      <Setter Property="Background" Value="{StaticResource SecondaryButton}" />
      <Setter Property="BorderBrush" Value="{StaticResource CardBorder}" />
      <Setter Property="BorderThickness" Value="1" />
      <Setter Property="FontSize" Value="13" />
      <Setter Property="FontWeight" Value="SemiBold" />
      <Setter Property="Cursor" Value="Hand" />
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="ButtonBorder" Background="{TemplateBinding Background}"
                    BorderBrush="{TemplateBinding BorderBrush}" BorderThickness="{TemplateBinding BorderThickness}"
                    CornerRadius="11">
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center" />
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="ButtonBorder" Property="Background" Value="{StaticResource SecondaryButtonHover}" />
              </Trigger>
              <Trigger Property="IsEnabled" Value="False">
                <Setter TargetName="ButtonBorder" Property="Opacity" Value="0.4" />
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <Style x:Key="ModeButtonStyle" TargetType="Button">
      <Setter Property="Height" Value="82" />
      <Setter Property="Padding" Value="16,12" />
      <Setter Property="HorizontalContentAlignment" Value="Stretch" />
      <Setter Property="Background" Value="#101727" />
      <Setter Property="BorderBrush" Value="{StaticResource CardBorder}" />
      <Setter Property="BorderThickness" Value="1" />
      <Setter Property="Cursor" Value="Hand" />
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="ModeBorder" Background="{TemplateBinding Background}"
                    BorderBrush="{TemplateBinding BorderBrush}" BorderThickness="{TemplateBinding BorderThickness}"
                    CornerRadius="13" Padding="{TemplateBinding Padding}">
              <ContentPresenter HorizontalAlignment="{TemplateBinding HorizontalContentAlignment}" />
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="ModeBorder" Property="Background" Value="#182238" />
              </Trigger>
              <Trigger Property="IsEnabled" Value="False">
                <Setter TargetName="ModeBorder" Property="Opacity" Value="0.45" />
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
  </Window.Resources>

  <Border Background="{StaticResource WindowBackground}" BorderBrush="#323D57" BorderThickness="1" CornerRadius="22">
    <Border.Effect>
      <DropShadowEffect Color="#000000" BlurRadius="28" ShadowDepth="8" Opacity="0.46" />
    </Border.Effect>
    <Grid>
      <Grid.RowDefinitions>
        <RowDefinition Height="64" />
        <RowDefinition Height="*" />
        <RowDefinition Height="42" />
      </Grid.RowDefinitions>

      <Grid x:Name="TitleBar" Grid.Row="0" Margin="20,10,14,4" Background="Transparent">
        <Grid.ColumnDefinitions>
          <ColumnDefinition Width="*" />
          <ColumnDefinition Width="Auto" />
        </Grid.ColumnDefinitions>
        <StackPanel Orientation="Horizontal" VerticalAlignment="Center">
          <Border Width="38" Height="38" CornerRadius="11" Background="#2A2458" BorderBrush="#6F61DE" BorderThickness="1">
            <TextBlock Text="H" Foreground="#DCD7FF" FontSize="18" FontWeight="Bold" HorizontalAlignment="Center" VerticalAlignment="Center" />
          </Border>
          <StackPanel Margin="12,0,0,0" VerticalAlignment="Center">
            <TextBlock Text="Hybrid MCP" Foreground="{StaticResource TextPrimary}" FontSize="16" FontWeight="SemiBold" />
            <TextBlock Text="Control Center" Foreground="{StaticResource TextSecondary}" FontSize="11" />
          </StackPanel>
        </StackPanel>
        <StackPanel Grid.Column="1" Orientation="Horizontal" VerticalAlignment="Center">
          <Button x:Name="MinimizeButton" Content="&#xE921;" FontFamily="Segoe MDL2 Assets"
                  Style="{StaticResource WindowButtonStyle}" ToolTip="Minimize" />
          <Button x:Name="CloseButton" Content="&#xE8BB;" FontFamily="Segoe MDL2 Assets"
                  Style="{StaticResource WindowButtonStyle}" ToolTip="Close" FontSize="13" />
        </StackPanel>
      </Grid>

      <ScrollViewer Grid.Row="1" VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Disabled" Margin="24,8,24,10">
        <StackPanel>
          <Border x:Name="ProfilePanel" Visibility="Collapsed" Background="#101727" BorderBrush="{StaticResource CardBorder}"
                  BorderThickness="1" CornerRadius="14" Padding="14,11" Margin="0,0,0,12">
            <Grid>
              <Grid.ColumnDefinitions>
                <ColumnDefinition Width="Auto" />
                <ColumnDefinition Width="12" />
                <ColumnDefinition Width="*" />
                <ColumnDefinition Width="12" />
                <ColumnDefinition Width="Auto" />
              </Grid.ColumnDefinitions>
              <TextBlock Text="PROFILE" Foreground="{StaticResource TextSecondary}" FontSize="10.5" FontWeight="Bold"
                         VerticalAlignment="Center" />
              <ComboBox x:Name="ProfileSelector" Grid.Column="2" Height="38" Padding="11,0"
                        Foreground="{StaticResource TextPrimary}" Background="#1C263B" BorderBrush="{StaticResource CardBorder}"
                        BorderThickness="1" FontSize="13" VerticalContentAlignment="Center" />
              <Button x:Name="AllProfilesButton" Grid.Column="4" Content="Connect all" Width="142" Height="38"
                      Style="{StaticResource SecondaryButtonStyle}" />
            </Grid>
          </Border>

          <Border x:Name="StatusCard" Background="{StaticResource CardBackground}" BorderBrush="{StaticResource CardBorder}"
                  BorderThickness="1" CornerRadius="20" Padding="26,24">
            <Grid>
              <Grid.ColumnDefinitions>
                <ColumnDefinition Width="*" />
                <ColumnDefinition Width="Auto" />
              </Grid.ColumnDefinitions>
              <StackPanel>
                <StackPanel Orientation="Horizontal">
                  <Ellipse x:Name="StatusDot" Width="10" Height="10" Fill="{StaticResource Accent}" Margin="0,1,9,0" />
                  <TextBlock x:Name="StatusBadge" Text="CHECKING" Foreground="{StaticResource Accent}"
                             FontSize="11" FontWeight="Bold" />
                </StackPanel>
                <TextBlock x:Name="StatusTitle" Text="Checking your connection..." Foreground="{StaticResource TextPrimary}"
                           FontSize="27" FontWeight="SemiBold" Margin="0,15,0,0" />
                <TextBlock x:Name="StatusDescription" Text="This will only take a moment." Foreground="{StaticResource TextSecondary}"
                           FontSize="14" TextWrapping="Wrap" MaxWidth="470" HorizontalAlignment="Left"
                           Margin="0,7,0,0" LineHeight="21" />
              </StackPanel>
              <Button x:Name="RefreshButton" Grid.Column="1" Content="&#xE72C;" FontFamily="Segoe MDL2 Assets"
                      Style="{StaticResource WindowButtonStyle}" Width="42" Height="42" FontSize="16"
                      ToolTip="Refresh status" VerticalAlignment="Top" />
            </Grid>
          </Border>

          <Border x:Name="IssuePanel" Visibility="Collapsed" Background="#2A1B25" BorderBrush="#6A3342"
                  BorderThickness="1" CornerRadius="13" Padding="15,12" Margin="0,12,0,0">
            <StackPanel Orientation="Horizontal">
              <TextBlock Text="!" Foreground="#FF8794" FontSize="14" FontWeight="Bold" Margin="0,0,10,0" />
              <TextBlock x:Name="IssueText" Foreground="#FFD8DD" FontSize="12.5" TextWrapping="Wrap" />
            </StackPanel>
          </Border>

          <Button x:Name="PrimaryActionButton" Content="Connect to ChatGPT" Style="{StaticResource PrimaryButtonStyle}" Margin="0,16,0,0" />

          <TextBlock Text="ACCESS MODE" Foreground="{StaticResource TextSecondary}" FontSize="11" FontWeight="Bold"
                     Margin="2,24,0,10" />
          <Grid>
            <Grid.ColumnDefinitions>
              <ColumnDefinition Width="*" />
              <ColumnDefinition Width="12" />
              <ColumnDefinition Width="*" />
            </Grid.ColumnDefinitions>
            <Button x:Name="ReadonlyModeButton" Grid.Column="0" Style="{StaticResource ModeButtonStyle}">
              <Grid>
                <Grid.ColumnDefinitions><ColumnDefinition Width="*" /><ColumnDefinition Width="Auto" /></Grid.ColumnDefinitions>
                <StackPanel>
                  <TextBlock Text="Read only" Foreground="{StaticResource TextPrimary}" FontSize="14" FontWeight="SemiBold" />
                  <TextBlock Text="Inspect files and approved windows" Foreground="{StaticResource TextSecondary}" FontSize="11.5" Margin="0,5,0,0" />
                </StackPanel>
                <TextBlock x:Name="ReadonlyCheck" Grid.Column="1" Text="&#x25CB;" FontFamily="Segoe UI Symbol"
                           Foreground="{StaticResource TextSecondary}" FontSize="17" VerticalAlignment="Center" />
              </Grid>
            </Button>
            <Button x:Name="FullModeButton" Grid.Column="2" Style="{StaticResource ModeButtonStyle}">
              <Grid>
                <Grid.ColumnDefinitions><ColumnDefinition Width="*" /><ColumnDefinition Width="Auto" /></Grid.ColumnDefinitions>
                <StackPanel>
                  <TextBlock Text="Full access" Foreground="{StaticResource TextPrimary}" FontSize="14" FontWeight="SemiBold" />
                  <TextBlock Text="Change files and run commands" Foreground="{StaticResource TextSecondary}" FontSize="11.5" Margin="0,5,0,0" />
                </StackPanel>
                <TextBlock x:Name="FullCheck" Grid.Column="1" Text="&#x25CB;" FontFamily="Segoe UI Symbol"
                           Foreground="{StaticResource TextSecondary}" FontSize="17" VerticalAlignment="Center" />
              </Grid>
            </Button>
          </Grid>
          <TextBlock Text="Changing access mode safely restarts an active connection." Foreground="#77839A" FontSize="11" Margin="3,8,0,0" />

          <Expander x:Name="AdvancedExpander" Margin="0,22,0,0" Foreground="{StaticResource TextPrimary}" Background="Transparent">
            <Expander.Header>
              <StackPanel Orientation="Horizontal">
                <TextBlock Text="Setup &amp; troubleshooting" FontSize="13" FontWeight="SemiBold" />
                <TextBlock Text="  /  advanced" Foreground="{StaticResource TextSecondary}" FontSize="12" />
              </StackPanel>
            </Expander.Header>
            <Border Background="{StaticResource CardBackground}" BorderBrush="{StaticResource CardBorder}" BorderThickness="1"
                    CornerRadius="15" Padding="14" Margin="0,12,0,0">
              <StackPanel>
                <Grid>
                  <Grid.ColumnDefinitions>
                    <ColumnDefinition Width="*" /><ColumnDefinition Width="10" /><ColumnDefinition Width="*" />
                  </Grid.ColumnDefinitions>
                  <Button x:Name="ConfigureButton" Grid.Column="0" Content="Tunnel setup" Style="{StaticResource SecondaryButtonStyle}" />
                  <Button x:Name="DoctorButton" Grid.Column="2" Content="Run connection check" Style="{StaticResource SecondaryButtonStyle}" />
                </Grid>
                <Grid Margin="0,10,0,0">
                  <Grid.ColumnDefinitions>
                    <ColumnDefinition Width="*" /><ColumnDefinition Width="10" /><ColumnDefinition Width="*" />
                  </Grid.ColumnDefinitions>
                  <Button x:Name="WindowAccessButton" Grid.Column="0" Content="Window access" Style="{StaticResource SecondaryButtonStyle}" />
                  <Button x:Name="DashboardButton" Grid.Column="2" Content="Local dashboard" Style="{StaticResource SecondaryButtonStyle}" />
                </Grid>
                <Grid Margin="0,10,0,0">
                  <Grid.ColumnDefinitions>
                    <ColumnDefinition Width="*" /><ColumnDefinition Width="10" /><ColumnDefinition Width="*" /><ColumnDefinition Width="10" /><ColumnDefinition Width="*" />
                  </Grid.ColumnDefinitions>
                  <Button x:Name="LogsButton" Grid.Column="0" Content="Open logs" Style="{StaticResource SecondaryButtonStyle}" />
                  <Button x:Name="CliButton" Grid.Column="2" Content="Classic menu" Style="{StaticResource SecondaryButtonStyle}" />
                  <Button x:Name="CopyDiagnosticsButton" Grid.Column="4" Content="Copy diagnostics" Style="{StaticResource SecondaryButtonStyle}" />
                </Grid>
              </StackPanel>
            </Border>
          </Expander>

          <Border x:Name="LastActionPanel" Visibility="Collapsed" Background="#0E1525" BorderBrush="#263149"
                  BorderThickness="1" CornerRadius="12" Padding="13" Margin="0,12,0,0">
            <TextBlock x:Name="LastActionText" Foreground="{StaticResource TextSecondary}" FontFamily="Consolas"
                       FontSize="11" TextWrapping="Wrap" MaxHeight="96" />
          </Border>
        </StackPanel>
      </ScrollViewer>

      <Grid Grid.Row="2" Margin="24,0">
        <Grid.ColumnDefinitions><ColumnDefinition Width="*" /><ColumnDefinition Width="Auto" /></Grid.ColumnDefinitions>
        <StackPanel Orientation="Horizontal" VerticalAlignment="Center">
          <ProgressBar x:Name="BusyIndicator" Width="72" Height="3" IsIndeterminate="True" Visibility="Collapsed"
                       Foreground="{StaticResource Accent}" Background="#1A2336" BorderThickness="0" Margin="0,0,10,0" />
          <TextBlock x:Name="FooterStatus" Text="Starting Control Center..." Foreground="#748096" FontSize="10.5" />
        </StackPanel>
        <TextBlock Grid.Column="1" Text="Secure MCP Tunnel" Foreground="#59657C" FontSize="10.5" VerticalAlignment="Center" />
      </Grid>
    </Grid>
  </Border>
</Window>
'@

$XmlReader = [Xml.XmlReader]::Create([IO.StringReader]::new($Xaml))
try {
  $Window = [Windows.Markup.XamlReader]::Load($XmlReader)
} finally {
  $XmlReader.Dispose()
}

$RequiredControlNames = @(
  "TitleBar", "MinimizeButton", "CloseButton", "StatusDot", "StatusBadge", "StatusTitle",
  "StatusDescription", "RefreshButton", "IssuePanel", "IssueText", "PrimaryActionButton",
  "ProfilePanel", "ProfileSelector", "AllProfilesButton",
  "ReadonlyModeButton", "FullModeButton", "ReadonlyCheck", "FullCheck", "AdvancedExpander",
  "ConfigureButton", "DoctorButton", "WindowAccessButton", "DashboardButton", "LogsButton",
  "CliButton", "CopyDiagnosticsButton", "LastActionPanel", "LastActionText", "BusyIndicator", "FooterStatus"
)
$Controls = @{}
foreach ($ControlName in $RequiredControlNames) {
  $Control = $Window.FindName($ControlName)
  if ($null -eq $Control) { throw "Control Center XAML is missing named control: $ControlName" }
  $Controls[$ControlName] = $Control
}

if ($ValidateOnly) {
  $Fixtures = @(
    Get-ControlCenterPresentation -Status ([pscustomobject]@{ running=$false; supervised=$false; desiredRunning=$false; stopRequested=$false; ready=$null; recoveryState=$null }) -StatusError ""
    Get-ControlCenterPresentation -Status ([pscustomobject]@{ running=$true; supervised=$true; desiredRunning=$true; stopRequested=$false; ready="ready"; recoveryState="ready" }) -StatusError ""
    Get-ControlCenterPresentation -Status ([pscustomobject]@{ running=$false; supervised=$true; desiredRunning=$true; stopRequested=$false; ready=$null; recoveryState="backoff"; recoveryNextDelaySeconds=10 }) -StatusError ""
    Get-ControlCenterPresentation -Status $null -StatusError "fixture status failure"
  )
  [pscustomobject]@{
    schema = "hybrid.controlCenterValidation.v1"
    windowLoaded = $true
    width = [int]$Window.Width
    height = [int]$Window.Height
    requiredControlCount = $RequiredControlNames.Count
    resolvedControlCount = $Controls.Count
    fixtureStates = @($Fixtures | ForEach-Object { [string]$_.state })
    fixtureActions = @($Fixtures | ForEach-Object { [string]$_.primaryAction })
    multiProfileControlsAvailable = $null -ne $Controls.ProfileSelector -and $null -ne $Controls.AllProfilesButton
  } | ConvertTo-Json -Depth 4
  $Window.Close()
  return
}

$BrushConverter = [Windows.Media.BrushConverter]::new()
function Get-ControlCenterBrush([string]$Color) {
  return [Windows.Media.Brush]$BrushConverter.ConvertFromString($Color)
}

function ConvertTo-ControlCenterArgument([string]$Value) {
  if ($null -eq $Value -or $Value.Length -eq 0) { return '""' }
  if ($Value -notmatch '[\s"]') { return $Value }

  $Builder = [Text.StringBuilder]::new()
  $null = $Builder.Append('"')
  $Backslashes = 0
  foreach ($Character in $Value.ToCharArray()) {
    if ($Character -eq '\') {
      $Backslashes += 1
      continue
    }
    if ($Character -eq '"') {
      $null = $Builder.Append(('\' * (($Backslashes * 2) + 1)))
      $null = $Builder.Append('"')
      $Backslashes = 0
      continue
    }
    if ($Backslashes -gt 0) {
      $null = $Builder.Append(('\' * $Backslashes))
      $Backslashes = 0
    }
    $null = $Builder.Append($Character)
  }
  if ($Backslashes -gt 0) { $null = $Builder.Append(('\' * ($Backslashes * 2))) }
  $null = $Builder.Append('"')
  return $Builder.ToString()
}

$script:CurrentStatus = $null
$script:CurrentPresentation = $null
$script:ProfileRecords = @()
$script:ProfilesInitialized = $false
$script:MultiProfileMode = $false
$script:AllProfilesActive = $false
$script:SelectedProfileId = $ProfileId
$script:ProfileSignature = ""
$script:UpdatingProfileSelector = $false
$script:ActiveCommand = $null
$script:NextRefreshAt = [DateTimeOffset]::MinValue
$script:Closing = $false

function Set-ControlCenterBusy([bool]$Busy, [string]$Label) {
  $Controls.BusyIndicator.Visibility = if ($Busy) { "Visible" } else { "Collapsed" }
  if (-not [string]::IsNullOrWhiteSpace($Label)) { $Controls.FooterStatus.Text = $Label }
  foreach ($Name in @(
    "PrimaryActionButton", "RefreshButton", "ReadonlyModeButton", "FullModeButton",
    "ConfigureButton", "DoctorButton", "WindowAccessButton", "ProfileSelector", "AllProfilesButton"
  )) {
    $Controls[$Name].IsEnabled = -not $Busy
  }
}

function Get-ControlCenterProfileId {
  return [string]$script:SelectedProfileId
}

function Show-ControlCenterMessage([string]$Message, [bool]$IsError = $false) {
  $Text = $Message.Trim()
  if ($Text.Length -gt 1800) { $Text = $Text.Substring(0, 1800) + "..." }
  $Controls.LastActionText.Text = $Text
  $Controls.LastActionText.Foreground = Get-ControlCenterBrush $(if ($IsError) { "#FF9BA6" } else { "#A8B2C7" })
  $Controls.LastActionPanel.Visibility = if ([string]::IsNullOrWhiteSpace($Text)) { "Collapsed" } else { "Visible" }
}

function Set-ControlCenterMode([string]$PermissionPreset) {
  $ReadonlySelected = $PermissionPreset -ceq "readonly"
  $FullSelected = $PermissionPreset -ceq "workstation"
  $SelectedBackground = Get-ControlCenterBrush "#292552"
  $SelectedBorder = Get-ControlCenterBrush "#8B7CFF"
  $DefaultBackground = Get-ControlCenterBrush "#101727"
  $DefaultBorder = Get-ControlCenterBrush "#263149"

  $Controls.ReadonlyModeButton.Background = if ($ReadonlySelected) { $SelectedBackground } else { $DefaultBackground }
  $Controls.ReadonlyModeButton.BorderBrush = if ($ReadonlySelected) { $SelectedBorder } else { $DefaultBorder }
  $Controls.ReadonlyModeButton.BorderThickness = if ($ReadonlySelected) { "2" } else { "1" }
  $Controls.ReadonlyCheck.Text = [string][char]$(if ($ReadonlySelected) { 0x25CF } else { 0x25CB })
  $Controls.ReadonlyCheck.Foreground = if ($ReadonlySelected) { $SelectedBorder } else { Get-ControlCenterBrush "#A8B2C7" }

  $Controls.FullModeButton.Background = if ($FullSelected) { $SelectedBackground } else { $DefaultBackground }
  $Controls.FullModeButton.BorderBrush = if ($FullSelected) { $SelectedBorder } else { $DefaultBorder }
  $Controls.FullModeButton.BorderThickness = if ($FullSelected) { "2" } else { "1" }
  $Controls.FullCheck.Text = [string][char]$(if ($FullSelected) { 0x25CF } else { 0x25CB })
  $Controls.FullCheck.Foreground = if ($FullSelected) { $SelectedBorder } else { Get-ControlCenterBrush "#A8B2C7" }
}

function Set-ControlCenterPresentation([object]$Presentation, [object]$Status) {
  $script:CurrentPresentation = $Presentation
  $AccentBrush = Get-ControlCenterBrush ([string]$Presentation.accent)
  $Controls.StatusDot.Fill = $AccentBrush
  $Controls.StatusBadge.Foreground = $AccentBrush
  $Controls.StatusBadge.Text = [string]$Presentation.badge
  $Controls.StatusTitle.Text = [string]$Presentation.title
  $Controls.StatusDescription.Text = [string]$Presentation.description
  $Controls.PrimaryActionButton.Content = [string]$Presentation.primaryText
  $Controls.IssuePanel.Visibility = if ([bool]$Presentation.issueVisible) { "Visible" } else { "Collapsed" }
  $Controls.IssueText.Text = [string]$Presentation.issueText

  $Preset = if ($null -ne $Status) { [string]$Status.permissionPreset } else { "" }
  Set-ControlCenterMode $Preset
  $Controls.DashboardButton.IsEnabled = -not $Preview -and $null -ne $Status -and -not [string]::IsNullOrWhiteSpace([string]$Status.adminUi)
  $Controls.LogsButton.IsEnabled = -not $Preview
  $Controls.CopyDiagnosticsButton.IsEnabled = -not $Preview -and $null -ne $Status
}

function Show-ControlCenterSelectedProfile {
  $Selected = @($script:ProfileRecords | Where-Object { [string]$_.id -ceq $script:SelectedProfileId } | Select-Object -First 1)
  if ($Selected.Count -ne 1) {
    $script:CurrentStatus = $null
    Set-ControlCenterPresentation (Get-ControlCenterPresentation -Status $null -StatusError "The selected profile is not registered.") $null
    return
  }

  $Record = $Selected[0]
  $StatusError = [string]$Record.error
  $Status = if ([string]::IsNullOrWhiteSpace($StatusError)) { $Record.status } else { $null }
  $script:CurrentStatus = $Status
  Set-ControlCenterPresentation (Get-ControlCenterPresentation -Status $Status -StatusError $StatusError) $Status
}

function Set-ControlCenterProfileRecords {
  param(
    [Parameter(Mandatory = $true)]
    [AllowEmptyCollection()]
    [object[]]$Records
  )

  if (@($Records).Count -lt 1) { throw "The profile status response did not contain a profile." }
  $script:ProfileRecords = @($Records)
  $script:ProfilesInitialized = $true
  $script:MultiProfileMode = @($Records).Count -gt 1
  $Controls.ProfilePanel.Visibility = if ($script:MultiProfileMode) { "Visible" } else { "Collapsed" }

  $ProfileIds = @($Records | ForEach-Object { [string]$_.id })
  $NewSignature = $ProfileIds -join "|"
  if ($NewSignature -cne $script:ProfileSignature) {
    $script:UpdatingProfileSelector = $true
    try {
      $Controls.ProfileSelector.Items.Clear()
      foreach ($Record in @($Records)) {
        $Item = [Windows.Controls.ComboBoxItem]::new()
        $Item.Tag = [string]$Record.id
        $Item.Content = [string]$Record.displayName
        $Item.ToolTip = [string]$Record.id
        $null = $Controls.ProfileSelector.Items.Add($Item)
      }
      $script:ProfileSignature = $NewSignature
    } finally {
      $script:UpdatingProfileSelector = $false
    }
  }

  if ($ProfileIds -cnotcontains $script:SelectedProfileId) { $script:SelectedProfileId = $ProfileIds[0] }
  $script:UpdatingProfileSelector = $true
  try {
    for ($Index = 0; $Index -lt $Controls.ProfileSelector.Items.Count; $Index += 1) {
      if ([string]$Controls.ProfileSelector.Items[$Index].Tag -ceq $script:SelectedProfileId) {
        $Controls.ProfileSelector.SelectedIndex = $Index
        break
      }
    }
  } finally {
    $script:UpdatingProfileSelector = $false
  }

  $ActiveCount = @($Records | Where-Object {
    [string]::IsNullOrWhiteSpace([string]$_.error) -and (Test-ControlCenterManagedStatusActive $_.status)
  }).Count
  $script:AllProfilesActive = $ActiveCount -eq @($Records).Count
  $Controls.AllProfilesButton.Content = if ($script:AllProfilesActive) {
    "Disconnect all"
  } elseif ($ActiveCount -gt 0) {
    "Connect remaining"
  } else {
    "Connect all"
  }
  $Controls.AllProfilesButton.ToolTip = "$ActiveCount of $(@($Records).Count) registered profiles are active or recovering."
  $Controls.ProfileSelector.IsEnabled = $script:MultiProfileMode -and $null -eq $script:ActiveCommand
  $Controls.AllProfilesButton.IsEnabled = $script:MultiProfileMode -and $null -eq $script:ActiveCommand -and -not $Preview
  Show-ControlCenterSelectedProfile
}

function Start-ControlCenterCommand {
  param(
    [Parameter(Mandatory = $true)][string]$ScriptPath,
    [string[]]$Arguments = @(),
    [Parameter(Mandatory = $true)][string]$Label,
    [Parameter(Mandatory = $true)][scriptblock]$OnComplete
  )

  if ($null -ne $script:ActiveCommand -or $Preview) { return $false }
  $CommandArguments = @("-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-File", $ScriptPath) + @($Arguments)
  $StartInfo = [Diagnostics.ProcessStartInfo]::new()
  $StartInfo.FileName = $PowerShellPath
  $StartInfo.Arguments = (@($CommandArguments | ForEach-Object { ConvertTo-ControlCenterArgument ([string]$_) }) -join " ")
  $StartInfo.WorkingDirectory = $ToolRoot
  $StartInfo.UseShellExecute = $false
  $StartInfo.CreateNoWindow = $true
  $StartInfo.WindowStyle = [Diagnostics.ProcessWindowStyle]::Hidden
  $StartInfo.RedirectStandardOutput = $true
  $StartInfo.RedirectStandardError = $true
  $StartInfo.StandardOutputEncoding = [Text.Encoding]::UTF8
  $StartInfo.StandardErrorEncoding = [Text.Encoding]::UTF8

  $Process = [Diagnostics.Process]::new()
  $Process.StartInfo = $StartInfo
  if (-not $Process.Start()) { throw "Could not start $Label." }
  $script:ActiveCommand = [pscustomobject]@{
    process = $Process
    stdoutTask = $Process.StandardOutput.ReadToEndAsync()
    stderrTask = $Process.StandardError.ReadToEndAsync()
    label = $Label
    onComplete = $OnComplete
  }
  Set-ControlCenterBusy $true $Label
  return $true
}

function Complete-ControlCenterCommand {
  if ($null -eq $script:ActiveCommand -or -not $script:ActiveCommand.process.HasExited) { return }
  $Command = $script:ActiveCommand
  $script:ActiveCommand = $null
  try {
    $Command.process.WaitForExit()
    $StandardOutput = [string]$Command.stdoutTask.Result
    $StandardError = [string]$Command.stderrTask.Result
    $ExitCode = [int]$Command.process.ExitCode
  } finally {
    $Command.process.Dispose()
  }
  Set-ControlCenterBusy $false ""
  $Completion = [scriptblock]$Command.onComplete
  try {
    & $Completion $ExitCode $StandardOutput $StandardError
  } catch {
    Show-ControlCenterMessage "The Control Center could not finish updating its view. $([string]$_.Exception.Message)" $true
    $script:NextRefreshAt = [DateTimeOffset]::Now.AddSeconds(5)
  }
}

function Request-ControlCenterStatus {
  if ($null -ne $script:ActiveCommand -or $Preview) { return }
  $null = Start-ControlCenterCommand `
    -ScriptPath $ManagerScript `
    -Arguments @("-Action", "status-all") `
    -Label "Checking registered connections..." `
    -OnComplete {
      param($ExitCode, $StandardOutput, $StandardError)
      $StatusError = ""
      if ($ExitCode -eq 0) {
        try {
          $Response = ($StandardOutput | Out-String) | ConvertFrom-Json -ErrorAction Stop
          if ([string]$Response.schema -cne "hybrid.multiProfileStatus.v1") {
            throw "The status response used an unknown schema."
          }
          Set-ControlCenterProfileRecords -Records @($Response.profiles)
        } catch {
          $StatusError = "The registered profile status response could not be read. $([string]$_.Exception.Message)"
        }
      } else {
        $StatusError = (@($StandardError, $StandardOutput) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }) -join [Environment]::NewLine
      }
      if (-not [string]::IsNullOrWhiteSpace($StatusError)) {
        $script:CurrentStatus = $null
        Set-ControlCenterPresentation (Get-ControlCenterPresentation -Status $null -StatusError $StatusError) $null
        Show-ControlCenterMessage "Status check failed. Open Setup & troubleshooting for connection tools." $true
      }
      $Now = [DateTimeOffset]::Now
      $Controls.FooterStatus.Text = "Updated $($Now.ToString('h:mm:ss tt'))"
      $script:NextRefreshAt = $Now.AddSeconds(15)
    }
}

function Invoke-ControlCenterLifecycle([string]$Action) {
  $SelectedProfileId = Get-ControlCenterProfileId
  $ScriptPath = if ($Action -ceq "start") { $StartScript } else { $StopScript }
  $Label = if ($Action -ceq "start") { "Connecting securely..." } else { "Disconnecting..." }
  $Completion = {
    param($ExitCode, $StandardOutput, $StandardError)
    $Combined = (@($StandardOutput, $StandardError) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }) -join [Environment]::NewLine
    if ($ExitCode -eq 0) {
      Show-ControlCenterMessage $(if ($Action -ceq "start") { "Connected successfully." } else { "Disconnected successfully." })
    } else {
      Show-ControlCenterMessage $(if ([string]::IsNullOrWhiteSpace($Combined)) { "$Label failed." } else { $Combined }) $true
    }
    Request-ControlCenterStatus
  }.GetNewClosure()
  $null = Start-ControlCenterCommand `
    -ScriptPath $ScriptPath `
    -Arguments @("-ProfileId", $SelectedProfileId) `
    -Label $Label `
    -OnComplete $Completion
}

function Invoke-ControlCenterAllLifecycle {
  $Action = if ($script:AllProfilesActive) { "stop-all" } else { "start-all" }
  if ($Action -ceq "stop-all") {
    $Choice = [Windows.MessageBox]::Show(
      "Disconnect every registered profile?",
      "Disconnect all profiles",
      [Windows.MessageBoxButton]::YesNo,
      [Windows.MessageBoxImage]::Question
    )
    if ($Choice -ne [Windows.MessageBoxResult]::Yes) { return }
  }
  $Label = if ($Action -ceq "start-all") { "Connecting registered profiles..." } else { "Disconnecting registered profiles..." }
  $Completion = {
    param($ExitCode, $StandardOutput, $StandardError)
    $Combined = (@($StandardOutput, $StandardError) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }) -join [Environment]::NewLine
    if ($ExitCode -eq 0) {
      Show-ControlCenterMessage $(if ([string]::IsNullOrWhiteSpace($Combined)) { "$Label completed." } else { $Combined })
    } else {
      Show-ControlCenterMessage $(if ([string]::IsNullOrWhiteSpace($Combined)) { "$Label failed." } else { $Combined }) $true
    }
    Request-ControlCenterStatus
  }.GetNewClosure()
  $null = Start-ControlCenterCommand `
    -ScriptPath $ManagerScript `
    -Arguments @("-Action", $Action) `
    -Label $Label `
    -OnComplete $Completion
}

function Invoke-ControlCenterDoctor {
  $SelectedProfileId = Get-ControlCenterProfileId
  $null = Start-ControlCenterCommand `
    -ScriptPath $DoctorScript `
    -Arguments @("-ProfileId", $SelectedProfileId, "-Online") `
    -Label "Running connection check..." `
    -OnComplete {
      param($ExitCode, $StandardOutput, $StandardError)
      $Combined = (@($StandardOutput, $StandardError) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }) -join [Environment]::NewLine
      if ($ExitCode -eq 0) {
        Show-ControlCenterMessage "Connection check passed. No problem was found."
      } else {
        Show-ControlCenterMessage $(if ([string]::IsNullOrWhiteSpace($Combined)) { "The connection check found a problem." } else { $Combined }) $true
      }
      Request-ControlCenterStatus
    }
}

function Invoke-ControlCenterPreset([string]$PermissionPreset) {
  $SelectedProfileId = Get-ControlCenterProfileId
  if ($null -ne $script:CurrentStatus -and [string]$script:CurrentStatus.permissionPreset -ceq $PermissionPreset) { return }
  if ($PermissionPreset -ceq "workstation") {
    $Choice = [Windows.MessageBox]::Show(
      "Full access lets ChatGPT change files and run commands as your Windows account. Continue?",
      "Enable full access",
      [Windows.MessageBoxButton]::YesNo,
      [Windows.MessageBoxImage]::Warning
    )
    if ($Choice -ne [Windows.MessageBoxResult]::Yes) { return }
  }
  $Label = if ($PermissionPreset -ceq "readonly") { "Enabling read-only mode..." } else { "Enabling full access..." }
  $Completion = {
    param($ExitCode, $StandardOutput, $StandardError)
    $Combined = (@($StandardOutput, $StandardError) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }) -join [Environment]::NewLine
    if ($ExitCode -eq 0) {
      Show-ControlCenterMessage $(if ($PermissionPreset -ceq "readonly") { "Read-only mode is active." } else { "Full access is active." })
    } else {
      Show-ControlCenterMessage $(if ([string]::IsNullOrWhiteSpace($Combined)) { "$Label failed." } else { $Combined }) $true
    }
    Request-ControlCenterStatus
  }.GetNewClosure()
  $null = Start-ControlCenterCommand `
    -ScriptPath $ControlScript `
    -Arguments @("-Action", "preset", "-ProfileId", $SelectedProfileId, "-PermissionPreset", $PermissionPreset) `
    -Label $Label `
    -OnComplete $Completion
}

function Open-ControlCenterTool([string]$ScriptPath, [string[]]$Arguments = @()) {
  if ($Preview) { return }
  $CommandArguments = @("-NoProfile", "-ExecutionPolicy", "Bypass", "-File", $ScriptPath) + @($Arguments)
  $StartInfo = [Diagnostics.ProcessStartInfo]::new()
  $StartInfo.FileName = $PowerShellPath
  $StartInfo.Arguments = (@($CommandArguments | ForEach-Object { ConvertTo-ControlCenterArgument ([string]$_) }) -join " ")
  $StartInfo.WorkingDirectory = $ToolRoot
  $StartInfo.UseShellExecute = $true
  $StartInfo.WindowStyle = [Diagnostics.ProcessWindowStyle]::Normal
  $null = [Diagnostics.Process]::Start($StartInfo)
}

function Open-ControlCenterPath([string]$Path) {
  if ($Preview -or [string]::IsNullOrWhiteSpace($Path)) { return }
  $StartInfo = [Diagnostics.ProcessStartInfo]::new()
  $StartInfo.FileName = $Path
  $StartInfo.UseShellExecute = $true
  $null = [Diagnostics.Process]::Start($StartInfo)
}

$Controls.TitleBar.Add_MouseLeftButtonDown({
  param($Sender, $EventArgs)
  if ($EventArgs.ClickCount -eq 2) {
    $Window.WindowState = if ($Window.WindowState -eq "Maximized") { "Normal" } else { "Maximized" }
  } else {
    $Window.DragMove()
  }
})
$Controls.MinimizeButton.Add_Click({ $Window.WindowState = "Minimized" })
$Controls.CloseButton.Add_Click({ $Window.Close() })
$Controls.RefreshButton.Add_Click({
  $script:NextRefreshAt = [DateTimeOffset]::MinValue
  Request-ControlCenterStatus
})
$Controls.ProfileSelector.Add_SelectionChanged({
  if ($script:UpdatingProfileSelector -or $null -eq $Controls.ProfileSelector.SelectedItem) { return }
  $script:SelectedProfileId = [string]$Controls.ProfileSelector.SelectedItem.Tag
  Show-ControlCenterSelectedProfile
})
$Controls.AllProfilesButton.Add_Click({ Invoke-ControlCenterAllLifecycle })
$Controls.PrimaryActionButton.Add_Click({
  if ($null -eq $script:CurrentPresentation) { return }
  switch ([string]$script:CurrentPresentation.primaryAction) {
    "start" { Invoke-ControlCenterLifecycle "start" }
    "stop" { Invoke-ControlCenterLifecycle "stop" }
    "doctor" { Invoke-ControlCenterDoctor }
  }
})
$Controls.ReadonlyModeButton.Add_Click({ Invoke-ControlCenterPreset "readonly" })
$Controls.FullModeButton.Add_Click({ Invoke-ControlCenterPreset "workstation" })
$Controls.ConfigureButton.Add_Click({ Open-ControlCenterTool $ConfigureScript @("-ProfileId", (Get-ControlCenterProfileId)) })
$Controls.DoctorButton.Add_Click({ Invoke-ControlCenterDoctor })
$Controls.WindowAccessButton.Add_Click({ Open-ControlCenterTool $ControlScript @("-Action", "windows", "-ProfileId", (Get-ControlCenterProfileId)) })
$Controls.DashboardButton.Add_Click({
  if ($null -eq $script:CurrentStatus) { return }
  $AdminUi = [string]$script:CurrentStatus.adminUi
  $Uri = $null
  if ([Uri]::TryCreate($AdminUi, [UriKind]::Absolute, [ref]$Uri) -and $Uri.Scheme -ceq "http" -and $Uri.Host -ceq "127.0.0.1") {
    Open-ControlCenterPath $AdminUi
  }
})
$Controls.LogsButton.Add_Click({
  $StateDirectory = if ($null -ne $script:CurrentStatus) { [string]$script:CurrentStatus.stateDirectory } else { "" }
  if ([string]::IsNullOrWhiteSpace($StateDirectory) -or -not (Test-Path -LiteralPath $StateDirectory -PathType Container)) {
    $StateDirectory = Join-Path $ToolRoot "runtime"
  }
  if (Test-Path -LiteralPath $StateDirectory -PathType Container) { Open-ControlCenterPath $StateDirectory }
})
$Controls.CliButton.Add_Click({ Open-ControlCenterTool $ControlScript @("-ProfileId", (Get-ControlCenterProfileId)) })
$Controls.CopyDiagnosticsButton.Add_Click({
  if ($null -eq $script:CurrentStatus) { return }
  $Diagnostic = [ordered]@{
    schema = "hybrid.controlCenterDiagnostics.v1"
    capturedAt = [DateTimeOffset]::UtcNow.ToString("o")
    profileId = Get-ControlCenterProfileId
    uiState = if ($null -ne $script:CurrentPresentation) { [string]$script:CurrentPresentation.state } else { "unknown" }
    permissionPreset = [string]$script:CurrentStatus.permissionPreset
    running = [bool]$script:CurrentStatus.running
    desiredRunning = [bool]$script:CurrentStatus.desiredRunning
    supervised = [bool]$script:CurrentStatus.supervised
    processState = [string]$script:CurrentStatus.processState
    supervisorState = [string]$script:CurrentStatus.supervisorState
    recoveryState = [string]$script:CurrentStatus.recoveryState
    recoveryFailureCount = $script:CurrentStatus.recoveryFailureCount
    ready = Test-ControlCenterReadyValue $script:CurrentStatus.ready
  }
  [Windows.Clipboard]::SetText(($Diagnostic | ConvertTo-Json -Depth 4))
  Show-ControlCenterMessage "Non-secret diagnostics copied to the clipboard."
})

$Timer = [Windows.Threading.DispatcherTimer]::new()
$Timer.Interval = [TimeSpan]::FromMilliseconds(250)
$Timer.Add_Tick({
  if ($script:Closing) { return }
  Complete-ControlCenterCommand
  if ($null -eq $script:ActiveCommand -and [DateTimeOffset]::Now -ge $script:NextRefreshAt) {
    Request-ControlCenterStatus
  }
})
$Window.Add_Closed({
  $script:Closing = $true
  $Timer.Stop()
  if ($null -ne $script:InstanceMutex) {
    try { $script:InstanceMutex.ReleaseMutex() } catch { }
    $script:InstanceMutex.Dispose()
    $script:InstanceMutex = $null
  }
})

if ($Preview) {
  $PreviewStatus = [pscustomobject]@{
    profileId = $ProfileId
    permissionPreset = "workstation"
    running = $true
    supervised = $true
    desiredRunning = $true
    stopRequested = $false
    ready = "ready"
    recoveryState = "ready"
    adminUi = "http://127.0.0.1:2098/ui"
    stateDirectory = Join-Path $ToolRoot "runtime"
  }
  $script:CurrentStatus = $PreviewStatus
  $script:ProfilesInitialized = $true
  $script:ProfileRecords = @([pscustomobject]@{
    id = $ProfileId
    displayName = "Hybrid Workstation"
    permissionPreset = "workstation"
    status = $PreviewStatus
    error = $null
  })
  Set-ControlCenterPresentation (Get-ControlCenterPresentation -Status $PreviewStatus -StatusError "") $PreviewStatus
  $Controls.FooterStatus.Text = "Preview mode / no system actions"
  Set-ControlCenterBusy $false "Preview mode / no system actions"
} else {
  $Timer.Start()
  $Window.Add_ContentRendered({ Request-ControlCenterStatus })
}

$null = $Window.ShowDialog()
