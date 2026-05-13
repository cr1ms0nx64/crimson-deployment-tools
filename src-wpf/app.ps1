Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
try {
  $script:Utf8NoBom = [System.Text.UTF8Encoding]::new($false)
  [Console]::OutputEncoding = $script:Utf8NoBom
  $OutputEncoding = $script:Utf8NoBom
} catch {}

Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName PresentationCore
Add-Type -AssemblyName WindowsBase
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.IO.Compression.FileSystem

try {
  Add-Type @"
using System;
using System.Runtime.InteropServices;
public static class CrimsonTaskbarIdentity {
  [DllImport("shell32.dll", SetLastError=true)]
  public static extern int SetCurrentProcessExplicitAppUserModelID([MarshalAs(UnmanagedType.LPWStr)] string appID);
}
"@
  [CrimsonTaskbarIdentity]::SetCurrentProcessExplicitAppUserModelID('Crimson.Deploy.Tool') | Out-Null
} catch {}


$script:Root = $env:CRIMSON_DEPLOYER_ROOT
if ([string]::IsNullOrWhiteSpace($script:Root)) {
  $script:Root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
}
$script:ConfigPath = Join-Path $script:Root 'config\servers.json'
$script:LogDir = Join-Path $script:Root 'logs'
New-Item -ItemType Directory -Force -Path $script:LogDir | Out-Null
$script:LogFile = Join-Path $script:LogDir ('crimson-deployer-wpf-' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '.log')

trap {
  $msg = $_.Exception.Message
  try {
    if ([string]::IsNullOrWhiteSpace($script:LogDir)) {
      $script:LogDir = Join-Path (Split-Path -Parent $MyInvocation.MyCommand.Path) 'logs'
    }
    New-Item -ItemType Directory -Force -Path $script:LogDir | Out-Null
    if ([string]::IsNullOrWhiteSpace($script:LogFile)) {
      $script:LogFile = Join-Path $script:LogDir ('crimson-deployer-wpf-startfehler-' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '.log')
    }
    Add-Content -LiteralPath $script:LogFile -Value ('[' + (Get-Date -Format 'yyyy-MM-dd HH:mm:ss.fff') + '] FATAL STARTFEHLER: ' + $msg) -Encoding UTF8
    Add-Content -LiteralPath $script:LogFile -Value ($_.ScriptStackTrace) -Encoding UTF8
  } catch {}
  try {
    Add-Type -AssemblyName PresentationFramework -ErrorAction SilentlyContinue
    [System.Windows.MessageBox]::Show("Crimson Deploy Tool konnte nicht starten.`n`n$msg`n`nDetails stehen im logs Ordner.", 'Crimson Deploy Tool Startfehler', 'OK', 'Error') | Out-Null
  } catch {}
  exit 1
}
$script:JobLogFile = $null
$script:LastJobLogCount = 0
$script:SelectedZip = ''
$script:SelectedServer = $null
$script:Servers = @()
$script:DeployJob = $null
$script:IsRunning = $false
$script:SelectedUpdatePackage = ''
$script:SelectedUpdateManifest = $null
$script:UpdateResultFile = Join-Path $script:LogDir 'last-update-result.log'
$script:AppVersion = '1.0.1'
$script:HistoryFile = Join-Path $script:LogDir 'deploy-history.json'
$script:DeployStateFile = Join-Path $script:LogDir 'deploy-state.json'
$script:DeployStateFileConfig = Join-Path (Join-Path $script:Root 'config') 'deploy-state.json'
$script:SettingsFile = Join-Path (Join-Path $script:Root 'config') 'app-settings.json'
$script:AppSettings = $null
$script:ServerHealth = @{}
$script:ServerHealthFile = Join-Path (Join-Path $script:Root 'config') 'server-health.json'
$script:HealthJob = $null
$script:HealthTimer = $null
$script:CurrentAction = ''
$script:CurrentStart = $null
$script:CurrentZipName = ''
$script:CurrentServerLabel = ''
$script:CurrentKind = ''
$script:CurrentRollbackVersion = ''
$script:RollbackSuccessRecorded = $false
$script:RollbackSelectedCard = $null
$script:DeploySuccessRecorded = $false
$script:StageHasError = $false
$script:AppIconSource = $null
$script:ToastTimer = $null

function Remove-LegacyRuntimeArtifacts() {
  try {
    $runtimeDir = Join-Path $script:Root 'runtime'
    if (Test-Path -LiteralPath $runtimeDir) {
      Get-ChildItem -LiteralPath $runtimeDir -Filter 'crimson-deployer-wpf-*.ps1' -File -ErrorAction SilentlyContinue | ForEach-Object {
        if ($_.Name -ne 'crimson-deployer-wpf-1.0.1.ps1') { Remove-Item -LiteralPath $_.FullName -Force -ErrorAction SilentlyContinue }
      }
      Get-ChildItem -LiteralPath $runtimeDir -Filter 'crimson-deployer-wpf-v*.ps1' -File -ErrorAction SilentlyContinue | ForEach-Object {
        Remove-Item -LiteralPath $_.FullName -Force -ErrorAction SilentlyContinue
      }
    }
  } catch {}
}
Remove-LegacyRuntimeArtifacts

[xml]$xaml = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Crimson Deploy Tool" Width="1320" Height="840" MinWidth="1060" MinHeight="720"
        WindowStartupLocation="CenterScreen" Background="#04070F" FontFamily="DM Sans, Segoe UI" AllowDrop="True" ShowInTaskbar="True">
  <Window.Resources>
    <SolidColorBrush x:Key="TextPrimary" Color="#DDE6F0"/>
    <SolidColorBrush x:Key="TextMuted" Color="#8FA3BE"/>
    <SolidColorBrush x:Key="TextDim" Color="#4A5E7A"/>
    <SolidColorBrush x:Key="BgVoid" Color="#04070F"/>
    <SolidColorBrush x:Key="BgBase" Color="#070C18"/>
    <SolidColorBrush x:Key="BgPanel" Color="#0A1020"/>
    <SolidColorBrush x:Key="BgCard" Color="#0D1528"/>
    <SolidColorBrush x:Key="BgLift" Color="#111E36"/>
    <SolidColorBrush x:Key="BorderSoft" Color="#183148"/>
    <SolidColorBrush x:Key="BorderCyan" Color="#224F63"/>
    <SolidColorBrush x:Key="Cyan" Color="#22D3EE"/>
    <SolidColorBrush x:Key="CyanDark" Color="#0891B2"/>
    <SolidColorBrush x:Key="Green" Color="#10B981"/>
    <SolidColorBrush x:Key="Red" Color="#EF4444"/>

    <Style x:Key="CrimsonScrollPageButton" TargetType="RepeatButton">
      <Setter Property="Focusable" Value="False"/>
      <Setter Property="IsTabStop" Value="False"/>
      <Setter Property="Template"><Setter.Value><ControlTemplate TargetType="RepeatButton"><Border Background="Transparent"/></ControlTemplate></Setter.Value></Setter>
    </Style>

    <Style x:Key="CrimsonScrollThumb" TargetType="Thumb">
      <Setter Property="Focusable" Value="False"/>
      <Setter Property="MinHeight" Value="44"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Thumb">
            <Border x:Name="ThumbShell" CornerRadius="3" Width="4" HorizontalAlignment="Center" Margin="0,4" Background="#0891B2">
              <Border.Effect><DropShadowEffect Color="#22D3EE" BlurRadius="9" ShadowDepth="0" Opacity="0.28"/></Border.Effect>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="ThumbShell" Property="Background" Value="#22D3EE"/></Trigger>
              <Trigger Property="IsDragging" Value="True"><Setter TargetName="ThumbShell" Property="Background" Value="#A5F3FC"/></Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <Style TargetType="ScrollBar">
      <Setter Property="SnapsToDevicePixels" Value="True"/>
      <Setter Property="OverridesDefaultStyle" Value="True"/>
      <Setter Property="Background" Value="Transparent"/>
      <Setter Property="Width" Value="8"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="ScrollBar">
            <Grid x:Name="Root" Width="8" Background="Transparent">
              <Track x:Name="PART_Track" IsDirectionReversed="True">
                <Track.DecreaseRepeatButton><RepeatButton Command="ScrollBar.PageUpCommand" Style="{StaticResource CrimsonScrollPageButton}"/></Track.DecreaseRepeatButton>
                <Track.Thumb><Thumb Style="{StaticResource CrimsonScrollThumb}"/></Track.Thumb>
                <Track.IncreaseRepeatButton><RepeatButton Command="ScrollBar.PageDownCommand" Style="{StaticResource CrimsonScrollPageButton}"/></Track.IncreaseRepeatButton>
              </Track>
            </Grid>
            <ControlTemplate.Triggers>
              <Trigger Property="Orientation" Value="Horizontal">
                <Setter TargetName="Root" Property="LayoutTransform"><Setter.Value><RotateTransform Angle="-90"/></Setter.Value></Setter>
                <Setter Property="Height" Value="8"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <Style x:Key="GlassButton" TargetType="Button">
      <Setter Property="Foreground" Value="#8FA3BE"/>
      <Setter Property="FontFamily" Value="DM Sans, Segoe UI"/>
      <Setter Property="FontSize" Value="12"/>
      <Setter Property="FontWeight" Value="SemiBold"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Padding" Value="14,8"/>
      <Setter Property="MinHeight" Value="34"/>
      <Setter Property="Background" Value="#0AFFFFFF"/>
      <Setter Property="BorderBrush" Value="#4722D3EE"/>
      <Setter Property="BorderThickness" Value="1"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="border" CornerRadius="6" Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}" BorderThickness="{TemplateBinding BorderThickness}" SnapsToDevicePixels="True">
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center" Margin="{TemplateBinding Padding}" RecognizesAccessKey="True"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="border" Property="Background" Value="#111E36"/>
                <Setter TargetName="border" Property="BorderBrush" Value="#8C22D3EE"/>
              </Trigger>
              <Trigger Property="IsKeyboardFocused" Value="True">
                <Setter TargetName="border" Property="BorderBrush" Value="#06B6D4"/>
              </Trigger>
              <Trigger Property="IsPressed" Value="True"><Setter TargetName="border" Property="Background" Value="#0D1528"/></Trigger>
              <Trigger Property="IsEnabled" Value="False"><Setter TargetName="border" Property="Opacity" Value="0.38"/></Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <Style x:Key="PrimaryButton" TargetType="Button">
      <Setter Property="Foreground" Value="#030C18"/>
      <Setter Property="FontFamily" Value="DM Sans, Segoe UI"/>
      <Setter Property="FontSize" Value="12"/>
      <Setter Property="FontWeight" Value="Bold"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Padding" Value="14,8"/>
      <Setter Property="MinHeight" Value="34"/>
      <Setter Property="BorderBrush" Value="#06B6D4"/>
      <Setter Property="BorderThickness" Value="1"/>
      <Setter Property="Background"><Setter.Value><LinearGradientBrush StartPoint="0,0" EndPoint="1,1"><GradientStop Color="#0891B2" Offset="0"/><GradientStop Color="#06B6D4" Offset="1"/></LinearGradientBrush></Setter.Value></Setter>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="border" CornerRadius="6" Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}" BorderThickness="{TemplateBinding BorderThickness}" SnapsToDevicePixels="True">
              <Border.Effect><DropShadowEffect Color="#06B6D4" BlurRadius="6" ShadowDepth="0" Opacity="0.30"/></Border.Effect>
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center" Margin="{TemplateBinding Padding}" RecognizesAccessKey="True"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="border" Property="Background"><Setter.Value><LinearGradientBrush StartPoint="0,0" EndPoint="1,1"><GradientStop Color="#06B6D4" Offset="0"/><GradientStop Color="#22D3EE" Offset="1"/></LinearGradientBrush></Setter.Value></Setter>
                <Setter TargetName="border" Property="Effect"><Setter.Value><DropShadowEffect Color="#06B6D4" BlurRadius="24" ShadowDepth="0" Opacity="0.36"/></Setter.Value></Setter>
                <Setter TargetName="border" Property="RenderTransform"><Setter.Value><TranslateTransform Y="-1"/></Setter.Value></Setter>
              </Trigger>
              <Trigger Property="IsKeyboardFocused" Value="True"><Setter TargetName="border" Property="BorderBrush" Value="#A5F3FC"/></Trigger>
              <Trigger Property="IsPressed" Value="True"><Setter TargetName="border" Property="RenderTransform"><Setter.Value><TranslateTransform Y="0"/></Setter.Value></Setter></Trigger>
              <Trigger Property="IsEnabled" Value="False"><Setter TargetName="border" Property="Opacity" Value="0.30"/></Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <Style x:Key="DangerButton" TargetType="Button">
      <Setter Property="Foreground" Value="#F87171"/>
      <Setter Property="FontFamily" Value="DM Sans, Segoe UI"/>
      <Setter Property="FontSize" Value="12"/>
      <Setter Property="FontWeight" Value="SemiBold"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Padding" Value="14,8"/>
      <Setter Property="MinHeight" Value="34"/>
      <Setter Property="Background" Value="#12EF4444"/>
      <Setter Property="BorderBrush" Value="#38EF4444"/>
      <Setter Property="BorderThickness" Value="1"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="border" CornerRadius="6" Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}" BorderThickness="{TemplateBinding BorderThickness}" SnapsToDevicePixels="True">
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center" Margin="{TemplateBinding Padding}" RecognizesAccessKey="True"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="border" Property="Background" Value="#24EF4444"/>
                <Setter TargetName="border" Property="BorderBrush" Value="#73EF4444"/>
                <Setter TargetName="border" Property="Effect"><Setter.Value><DropShadowEffect Color="#EF4444" BlurRadius="12" ShadowDepth="0" Opacity="0.18"/></Setter.Value></Setter>
              </Trigger>
              <Trigger Property="IsKeyboardFocused" Value="True"><Setter TargetName="border" Property="BorderBrush" Value="#F87171"/></Trigger>
              <Trigger Property="IsEnabled" Value="False"><Setter TargetName="border" Property="Opacity" Value="0.38"/></Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <Style x:Key="GhostButton" TargetType="Button">
      <Setter Property="Foreground" Value="#4A5E7A"/>
      <Setter Property="FontFamily" Value="DM Sans, Segoe UI"/>
      <Setter Property="FontSize" Value="12"/>
      <Setter Property="FontWeight" Value="SemiBold"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Padding" Value="14,8"/>
      <Setter Property="MinHeight" Value="34"/>
      <Setter Property="Background" Value="Transparent"/>
      <Setter Property="BorderBrush" Value="Transparent"/>
      <Setter Property="BorderThickness" Value="1"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="border" CornerRadius="6" Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}" BorderThickness="{TemplateBinding BorderThickness}" SnapsToDevicePixels="True">
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center" Margin="{TemplateBinding Padding}" RecognizesAccessKey="True"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="border" Property="Background" Value="#111E36"/>
                <Setter Property="Foreground" Value="#8FA3BE"/>
              </Trigger>
              <Trigger Property="IsKeyboardFocused" Value="True"><Setter TargetName="border" Property="BorderBrush" Value="#06B6D4"/></Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <Style x:Key="ServerButtonStyle" TargetType="Button">
      <Setter Property="HorizontalContentAlignment" Value="Stretch"/>
      <Setter Property="VerticalContentAlignment" Value="Stretch"/>
      <Setter Property="Height" Value="99"/>
      <Setter Property="Margin" Value="0,0,0,7"/>
      <Setter Property="Padding" Value="0"/>
      <Setter Property="Background" Value="#0A1020"/>
      <Setter Property="BorderBrush" Value="#0D22D3EE"/>
      <Setter Property="BorderThickness" Value="1"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="border" CornerRadius="10" Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}" BorderThickness="{TemplateBinding BorderThickness}" SnapsToDevicePixels="True">
              <ContentPresenter HorizontalAlignment="Stretch" VerticalAlignment="Stretch" Margin="{TemplateBinding Padding}"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="border" Property="Background" Value="#111E36"/>
                <Setter TargetName="border" Property="BorderBrush" Value="#4722D3EE"/>
                <Setter TargetName="border" Property="Effect"><Setter.Value><DropShadowEffect Color="#06B6D4" BlurRadius="10" ShadowDepth="0" Opacity="0.10"/></Setter.Value></Setter>
              </Trigger>
              <Trigger Property="IsKeyboardFocused" Value="True"><Setter TargetName="border" Property="BorderBrush" Value="#06B6D4"/></Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <Style TargetType="ProgressBar">
      <Setter Property="Height" Value="8"/>
      <Setter Property="Foreground" Value="#22D3EE"/>
      <Setter Property="Background" Value="#111E36"/>
      <Setter Property="BorderBrush" Value="#183148"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="ProgressBar">
            <Grid ClipToBounds="True" SnapsToDevicePixels="True">
              <Border CornerRadius="5" Background="#111E36" BorderBrush="#183148" BorderThickness="1"/>
              <Border x:Name="PART_Track" Margin="1" CornerRadius="4" Background="Transparent"/>
              <Border x:Name="PART_Indicator" HorizontalAlignment="Left" Margin="1" CornerRadius="4">
                <Border.Background><LinearGradientBrush StartPoint="0,0" EndPoint="1,0"><GradientStop Color="#0891B2" Offset="0"/><GradientStop Color="#22D3EE" Offset="0.58"/><GradientStop Color="#0EA5E9" Offset="1"/></LinearGradientBrush></Border.Background>
                <Border.Effect><DropShadowEffect Color="#22D3EE" BlurRadius="16" ShadowDepth="0" Opacity="0.52"/></Border.Effect>
              </Border>
            </Grid>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
  </Window.Resources>

  <Grid>
    <Grid.Background>
      <RadialGradientBrush Center="0.14,0.0" GradientOrigin="0.14,0.0" RadiusX="0.9" RadiusY="0.72">
        <GradientStop Color="#112238" Offset="0"/>
        <GradientStop Color="#070C18" Offset="0.52"/>
        <GradientStop Color="#04070F" Offset="1"/>
      </RadialGradientBrush>
    </Grid.Background>
    <Grid.ColumnDefinitions>
      <ColumnDefinition Width="300"/>
      <ColumnDefinition Width="*"/>
    </Grid.ColumnDefinitions>

    <Border Grid.Column="0" Background="#D9070C18" BorderBrush="#183148" BorderThickness="0,0,1,0">
      <Grid>
        <Grid.RowDefinitions>
          <RowDefinition Height="Auto"/>
          <RowDefinition Height="Auto"/>
          <RowDefinition Height="*"/>
          <RowDefinition Height="Auto"/>
        </Grid.RowDefinitions>

        <StackPanel Grid.Row="0" Margin="18,18,18,12">
          <Image x:Name="LogoImage" Height="48" Stretch="Uniform" HorizontalAlignment="Left" Margin="0,0,0,10"/>
          <StackPanel Orientation="Horizontal" HorizontalAlignment="Left">
            <Border CornerRadius="4" BorderBrush="#224F63" BorderThickness="1" Background="#151D2C" Padding="8,3">
              <TextBlock Text="DEPLOY TOOL" Foreground="#22D3EE" FontSize="10" FontWeight="Bold" FontFamily="JetBrains Mono, Cascadia Mono, Consolas"/>
            </Border>
            <Border CornerRadius="4" BorderBrush="#183148" BorderThickness="1" Background="#0A1020" Padding="8,3" Margin="6,0,0,0">
              <TextBlock x:Name="VersionText" Text="1.0.0" Foreground="#4A5E7A" FontSize="10" FontWeight="Bold" FontFamily="JetBrains Mono, Cascadia Mono, Consolas"/>
            </Border>
          </StackPanel>
          <TextBlock x:Name="LastUpdateText" Text="" Visibility="Collapsed"/>
        </StackPanel>

        <StackPanel Grid.Row="1" Margin="12,0,12,8">
          <TextBlock Text="Zielserver" Foreground="#4A5E7A" FontSize="10" FontWeight="Bold" Margin="4,0,0,8"/>
          <StackPanel x:Name="ServerList" Margin="0,0,8,0"/>
        </StackPanel>

        <ScrollViewer Grid.Row="2" VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Disabled" CanContentScroll="False" Background="Transparent" Margin="0,0,4,0">
          <StackPanel Margin="12,2,12,12">
            <TextBlock Text="Aktionen" Foreground="#4A5E7A" FontSize="10" FontWeight="Bold" Margin="8,6,0,6"/>
            <Button x:Name="PreflightButton" Content="🔍  Preflight prüfen" Style="{StaticResource GlassButton}" HorizontalAlignment="Stretch" Margin="0,0,0,5"/>
            <Button x:Name="RollbackButton" Content="↩  Rollback starten" Style="{StaticResource GlassButton}" HorizontalAlignment="Stretch" Margin="0,0,0,5"/>
            <Button x:Name="HistoryButton" Content="📋  Deploy Verlauf" Style="{StaticResource GlassButton}" HorizontalAlignment="Stretch" Margin="0,0,0,5"/>
            <TextBlock Text="Verwaltung" Foreground="#4A5E7A" FontSize="10" FontWeight="Bold" Margin="8,12,0,6"/>
            <Button x:Name="ServerManagerButton" Content="🖥  Server verwalten" Style="{StaticResource GlassButton}" HorizontalAlignment="Stretch" Margin="0,0,0,5"/>
            <Button x:Name="RefreshServerStatusButton" Content="📡  Online Status prüfen" Style="{StaticResource GlassButton}" HorizontalAlignment="Stretch" Margin="0,0,0,5"/>
            <Button x:Name="ExportLogsButton" Content="📦  Support Paket erstellen" Style="{StaticResource GlassButton}" HorizontalAlignment="Stretch" Margin="0,0,0,5"/>
            <Button x:Name="CloudBackupButton" Content="💾  Config Backup erstellen" Style="{StaticResource GlassButton}" HorizontalAlignment="Stretch" Margin="0,0,0,5"/>
            <Button x:Name="RestoreBackupButton" Content="⬆  Config Backup laden" Style="{StaticResource GlassButton}" HorizontalAlignment="Stretch" Margin="0,0,0,5"/>
            <Button x:Name="SettingsButton" Content="⚙  Einstellungen" Style="{StaticResource GlassButton}" HorizontalAlignment="Stretch" Margin="0,0,0,8"/>
          </StackPanel>
        </ScrollViewer>

        <Border Grid.Row="3" Background="#0A1020" BorderBrush="#183148" BorderThickness="1" CornerRadius="10" Margin="12" Padding="12">
          <StackPanel>
            <TextBlock Text="⬇  App Update" Foreground="#8FA3BE" FontSize="12" FontWeight="SemiBold" Margin="0,0,0,2"/>
            <TextBlock x:Name="UpdateText" Text="Kein Update Paket gewählt" Foreground="#4A5E7A" FontSize="11" TextWrapping="Wrap" Margin="0,0,0,9"/>
            <Button x:Name="PickUpdateButton" Content="Update Paket wählen" Style="{StaticResource GlassButton}" Padding="8,5" Margin="0,0,0,5"/>
            <Button x:Name="InstallUpdateButton" Content="Installieren &amp; neu starten" Style="{StaticResource PrimaryButton}" Padding="8,5" IsEnabled="False"/>
          </StackPanel>
        </Border>
      </Grid>
    </Border>

    <Grid Grid.Column="1">
      <Grid.RowDefinitions>
        <RowDefinition Height="48"/>
        <RowDefinition Height="*"/>
      </Grid.RowDefinitions>

      <Border Grid.Row="0" Background="#B8070C18" BorderBrush="#0E2234" BorderThickness="0,0,0,1" Padding="22,0">
        <Grid>
          <StackPanel Orientation="Horizontal" VerticalAlignment="Center">
            <TextBlock Text="Server" Foreground="#4A5E7A" FontSize="12" Margin="0,0,6,0"/>
            <TextBlock Text="Server" Foreground="#22D3EE" FontSize="12" FontWeight="SemiBold" TextTrimming="CharacterEllipsis" MaxWidth="520"/>
          </StackPanel>
          <StackPanel Orientation="Horizontal" HorizontalAlignment="Right" VerticalAlignment="Center">
            <TextBlock Text="ZIP bereit" Foreground="#8FA3BE" FontSize="11" TextTrimming="CharacterEllipsis" MaxWidth="420"/>
          </StackPanel>
        </Grid>
      </Border>

      <ScrollViewer Grid.Row="1" VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Disabled" CanContentScroll="False">
        <StackPanel Margin="22,18,22,18">
          <Border CornerRadius="14" Background="#0D1528" BorderBrush="#183148" BorderThickness="1" Padding="18" Margin="0,0,0,14">
            <Grid>
              <Grid.RowDefinitions>
                <RowDefinition Height="Auto"/>
                <RowDefinition Height="12"/>
                <RowDefinition Height="Auto"/>
              </Grid.RowDefinitions>
              <Grid Grid.Row="0">
                <TextBlock Text="Deploy Paket" Foreground="#4A5E7A" FontSize="10" FontWeight="Bold"/>
                <TextBlock Text="ZIP auswählen oder direkt per Drag &amp; Drop ins Fenster ziehen" HorizontalAlignment="Right" Foreground="#4A5E7A" FontSize="11"/>
              </Grid>
              <Grid Grid.Row="2">
                <Grid.ColumnDefinitions>
                  <ColumnDefinition Width="*"/>
                  <ColumnDefinition Width="14"/>
                  <ColumnDefinition Width="136"/>
                </Grid.ColumnDefinitions>
                <Border x:Name="DropZone" Grid.Column="0" CornerRadius="10" Background="#050B13" BorderBrush="#224F63" BorderThickness="1.4" Padding="18" Cursor="Hand">
                  <Grid>
                    <Grid.ColumnDefinitions>
                      <ColumnDefinition Width="42"/>
                      <ColumnDefinition Width="*"/>
                    </Grid.ColumnDefinitions>
                    <Border Width="30" Height="30" CornerRadius="8" Background="#0A2030" BorderBrush="#224F63" BorderThickness="1" VerticalAlignment="Center">
                      <TextBlock Text="📦" HorizontalAlignment="Center" VerticalAlignment="Center" FontSize="15"/>
                    </Border>
                    <StackPanel Grid.Column="1" VerticalAlignment="Center">
                      <TextBlock x:Name="ZipText" Text="ZIP hier ablegen oder über den Button auswählen" Foreground="#DDE6F0" FontSize="13" FontWeight="SemiBold" TextTrimming="CharacterEllipsis"/>
                      <TextBlock Text="Validierung, Versionscheck und Zielerkennung laufen automatisch." Foreground="#4A5E7A" FontSize="11" Margin="0,2,0,0"/>
                    </StackPanel>
                  </Grid>
                </Border>
                <StackPanel Grid.Column="2" VerticalAlignment="Center">
                  <Button x:Name="DeployButton" Content="🚀  Deploy starten" Style="{StaticResource PrimaryButton}" Width="136" HorizontalAlignment="Stretch" Margin="0,0,0,7"/>
                  <Button x:Name="PickZipButton" Content="📂  ZIP wählen" Style="{StaticResource GlassButton}" Width="136" HorizontalAlignment="Stretch" Margin="0,0,0,7"/>
                  <Button x:Name="CancelButton" Content="✕  Abbrechen" Style="{StaticResource DangerButton}" Width="136" HorizontalAlignment="Stretch" IsEnabled="False"/>
                </StackPanel>
              </Grid>
            </Grid>
          </Border>

          <Border CornerRadius="14" Background="#0D1528" BorderBrush="#224F63" BorderThickness="1" Margin="0,0,0,14">
            <Grid>
              <Grid.RowDefinitions>
                <RowDefinition Height="Auto"/>
                <RowDefinition Height="*"/>
              </Grid.RowDefinitions>
              <Border Grid.Row="0" BorderBrush="#183148" BorderThickness="0,0,0,1" Padding="18,12">
                <Grid>
                  <TextBlock Text="Deployment Status" Foreground="#4A5E7A" FontSize="10" FontWeight="Bold" VerticalAlignment="Center"/>
                  <Border x:Name="StatusPill" HorizontalAlignment="Right" VerticalAlignment="Center" CornerRadius="8" Background="#0E3A27" BorderBrush="#10B981" BorderThickness="1" Padding="12,6">
                    <StackPanel Orientation="Horizontal">
                      <Ellipse Width="6" Height="6" Fill="#10B981" Margin="0,0,7,0" VerticalAlignment="Center"/>
                      <TextBlock x:Name="StatusText" Text="Bereit" Foreground="#34D399" FontWeight="SemiBold" FontSize="11"/>
                    </StackPanel>
                  </Border>
                </Grid>
              </Border>

              <Grid Grid.Row="1" MinHeight="260">
                <Grid.ColumnDefinitions>
                  <ColumnDefinition Width="*"/>
                  <ColumnDefinition Width="280"/>
                </Grid.ColumnDefinitions>
                <Border Grid.Column="0" BorderBrush="#183148" BorderThickness="0,0,1,0" Padding="26,24">
                  <StackPanel>
                    <StackPanel Orientation="Horizontal" Margin="0,0,0,22">
                      <Grid Width="74" Height="74" Margin="0,0,22,0">
                        <Ellipse Stroke="#224F63" StrokeThickness="1" Width="74" Height="74"/>
                        <Ellipse Stroke="#22D3EE" StrokeThickness="1" Width="60" Height="60" Opacity="0.45"/>
                        <Border Width="56" Height="56" CornerRadius="28" Background="#111E36" BorderBrush="#22D3EE" BorderThickness="1.4">
                          <Border.Effect><DropShadowEffect Color="#22D3EE" BlurRadius="22" ShadowDepth="0" Opacity="0.30"/></Border.Effect>
                          <TextBlock Text="↯" Foreground="#22D3EE" FontSize="28" FontWeight="Bold" HorizontalAlignment="Center" VerticalAlignment="Center"/>
                        </Border>
                      </Grid>
                      <StackPanel VerticalAlignment="Center">
                        <TextBlock Text="Aktueller Schritt" Foreground="#4A5E7A" FontSize="10" FontWeight="Bold"/>
                        <TextBlock x:Name="StepText" Text="Bereit" Foreground="#DDE6F0" FontSize="28" FontWeight="Bold" FontFamily="Rajdhani, Segoe UI" Margin="0,2,0,3" TextTrimming="CharacterEllipsis"/>
                        <TextBlock x:Name="LogSummaryText" Text="Bereit" Foreground="#4A5E7A" FontSize="11" TextTrimming="CharacterEllipsis" MaxWidth="620"/>
                      </StackPanel>
                    </StackPanel>

                    <Grid Margin="0,0,0,8">
                      <TextBlock Text="Gesamtfortschritt" Foreground="#4A5E7A" FontSize="11" VerticalAlignment="Bottom"/>
                      <TextBlock x:Name="StatusPercentText" Text="0%" HorizontalAlignment="Right" Foreground="#22D3EE" FontSize="22" FontWeight="Bold"/>
                    </Grid>
                    <ProgressBar x:Name="StepProgress" Minimum="0" Maximum="100" Value="0" Margin="0,0,0,13"/>
                    <UniformGrid Columns="6">
                      <Border x:Name="StageZip" CornerRadius="20" Background="#111E36" BorderBrush="#0D22D3EE" BorderThickness="1" Padding="12,5" Margin="0,0,6,0"><StackPanel Orientation="Horizontal" HorizontalAlignment="Center"><Ellipse Width="5" Height="5" Fill="#4A5E7A" Margin="0,0,5,0" VerticalAlignment="Center"/><TextBlock Text="ZIP" Foreground="#4A5E7A" FontFamily="JetBrains Mono, Cascadia Mono, Consolas" FontSize="9.5" FontWeight="SemiBold"/></StackPanel></Border>
                      <Border x:Name="StageCheck" CornerRadius="20" Background="#111E36" BorderBrush="#0D22D3EE" BorderThickness="1" Padding="12,5" Margin="0,0,6,0"><StackPanel Orientation="Horizontal" HorizontalAlignment="Center"><Ellipse Width="5" Height="5" Fill="#4A5E7A" Margin="0,0,5,0" VerticalAlignment="Center"/><TextBlock Text="CHECK" Foreground="#4A5E7A" FontFamily="JetBrains Mono, Cascadia Mono, Consolas" FontSize="9.5" FontWeight="SemiBold"/></StackPanel></Border>
                      <Border x:Name="StageUpload" CornerRadius="20" Background="#111E36" BorderBrush="#0D22D3EE" BorderThickness="1" Padding="12,5" Margin="0,0,6,0"><StackPanel Orientation="Horizontal" HorizontalAlignment="Center"><Ellipse Width="5" Height="5" Fill="#4A5E7A" Margin="0,0,5,0" VerticalAlignment="Center"/><TextBlock Text="UPLOAD" Foreground="#4A5E7A" FontFamily="JetBrains Mono, Cascadia Mono, Consolas" FontSize="9.5" FontWeight="SemiBold"/></StackPanel></Border>
                      <Border x:Name="StageBuild" CornerRadius="20" Background="#111E36" BorderBrush="#0D22D3EE" BorderThickness="1" Padding="12,5" Margin="0,0,6,0"><StackPanel Orientation="Horizontal" HorizontalAlignment="Center"><Ellipse Width="5" Height="5" Fill="#4A5E7A" Margin="0,0,5,0" VerticalAlignment="Center"/><TextBlock Text="BUILD" Foreground="#4A5E7A" FontFamily="JetBrains Mono, Cascadia Mono, Consolas" FontSize="9.5" FontWeight="SemiBold"/></StackPanel></Border>
                      <Border x:Name="StageHealth" CornerRadius="20" Background="#111E36" BorderBrush="#0D22D3EE" BorderThickness="1" Padding="12,5" Margin="0,0,6,0"><StackPanel Orientation="Horizontal" HorizontalAlignment="Center"><Ellipse Width="5" Height="5" Fill="#4A5E7A" Margin="0,0,5,0" VerticalAlignment="Center"/><TextBlock Text="HEALTH" Foreground="#4A5E7A" FontFamily="JetBrains Mono, Cascadia Mono, Consolas" FontSize="9.5" FontWeight="SemiBold"/></StackPanel></Border>
                      <Border x:Name="StageDone" CornerRadius="20" Background="#111E36" BorderBrush="#0D22D3EE" BorderThickness="1" Padding="12,5"><StackPanel Orientation="Horizontal" HorizontalAlignment="Center"><Ellipse Width="5" Height="5" Fill="#4A5E7A" Margin="0,0,5,0" VerticalAlignment="Center"/><TextBlock Text="DONE" Foreground="#4A5E7A" FontFamily="JetBrains Mono, Cascadia Mono, Consolas" FontSize="9.5" FontWeight="SemiBold"/></StackPanel></Border>
                    </UniformGrid>
                  </StackPanel>
                </Border>

                <StackPanel Grid.Column="1" Margin="18" VerticalAlignment="Stretch">
                  <TextBlock Text="Zielserver" Foreground="#4A5E7A" FontSize="10" FontWeight="Bold" Margin="0,0,0,4"/>
                  <TextBlock x:Name="SelectedServerSummary" Text="Server: wird geladen" Foreground="#22D3EE" FontSize="12" FontWeight="SemiBold" TextWrapping="Wrap"/>
                  <Border Height="1" Background="#183148" Margin="0,14,0,14"/>
                  <TextBlock Text="Paket" Foreground="#4A5E7A" FontSize="10" FontWeight="Bold" Margin="0,0,0,4"/>
                  <TextBlock x:Name="SelectedZipSummary" Text="ZIP: keine Datei gewählt" Foreground="#DDE6F0" FontSize="12" FontWeight="SemiBold" TextWrapping="Wrap"/>
                  <Border Height="1" Background="#183148" Margin="0,14,0,14"/>
                  <StackPanel Margin="0,0,0,0">
                    <Button x:Name="ToggleLogButton" Content="📄  Log anzeigen" Style="{StaticResource GlassButton}" Padding="8,5" Margin="0,0,0,6"/>
                    <Button x:Name="OpenLogsButton" Content="📁  Log Ordner" Style="{StaticResource GhostButton}" Padding="8,5" Margin="0,0,0,6"/>
                    <Button x:Name="ClearLogsButton" Content="🗑  Logs leeren" Style="{StaticResource DangerButton}" Padding="8,5"/>
                  </StackPanel>
                </StackPanel>
              </Grid>
            </Grid>
          </Border>

          <Border x:Name="LogContainer" CornerRadius="14" Background="#070C18" BorderBrush="#183148" BorderThickness="1" Padding="14" Height="410" Visibility="Collapsed">
            <Grid>
              <Grid.RowDefinitions>
                <RowDefinition Height="Auto"/>
                <RowDefinition Height="10"/>
                <RowDefinition Height="*"/>
              </Grid.RowDefinitions>
              <Grid Grid.Row="0">
                <Grid.ColumnDefinitions>
                  <ColumnDefinition Width="Auto"/>
                  <ColumnDefinition Width="12"/>
                  <ColumnDefinition Width="*"/>
                </Grid.ColumnDefinitions>
                <Border Grid.Column="0" Width="42" CornerRadius="5" Background="#FF3838" Padding="5,3" HorizontalAlignment="Left" VerticalAlignment="Top">
                  <Border.Effect><DropShadowEffect Color="#FF0000" BlurRadius="9" ShadowDepth="0" Opacity="0.70"/></Border.Effect>
                  <TextBlock Text="LIVE" Foreground="#FFFFFF" FontFamily="JetBrains Mono, Cascadia Mono, Consolas" FontSize="12" FontWeight="Bold" TextAlignment="Center" HorizontalAlignment="Center"/>
                </Border>
                <StackPanel Grid.Column="2" Orientation="Vertical">
                  <TextBlock Text="Deployment Livefeed" Foreground="#DDE6F0" FontFamily="Rajdhani, Segoe UI" FontSize="18" FontWeight="Bold"/>
                  <TextBlock x:Name="LogPathText" Text="Datei Log wird vorbereitet..." Foreground="#4A5E7A" FontSize="10" FontFamily="JetBrains Mono, Cascadia Mono, Consolas" TextTrimming="CharacterEllipsis"/>
                </StackPanel>
              </Grid>
              <Border Grid.Row="2" CornerRadius="10" Background="#040810" BorderBrush="#183148" BorderThickness="1" Padding="0">
                <RichTextBox x:Name="LogBox" Background="Transparent" Foreground="#DDE6F0" BorderThickness="0" IsReadOnly="True" VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Disabled" FontFamily="JetBrains Mono, Cascadia Mono, Consolas" FontSize="9.5" Padding="8" IsDocumentEnabled="False"/>
              </Border>
            </Grid>
          </Border>
        </StackPanel>
      </ScrollViewer>
    </Grid>

    <Border x:Name="ToastHost" Grid.ColumnSpan="2" Panel.ZIndex="50" HorizontalAlignment="Right" VerticalAlignment="Top" Margin="0,18,18,0" Width="360" CornerRadius="14" Background="#F20A1020" BorderBrush="#4722D3EE" BorderThickness="1" Padding="14" Visibility="Collapsed">
      <Border.Effect><DropShadowEffect Color="#22D3EE" BlurRadius="22" ShadowDepth="0" Opacity="0.22"/></Border.Effect>
      <Grid>
        <Grid.ColumnDefinitions>
          <ColumnDefinition Width="34"/>
          <ColumnDefinition Width="*"/>
        </Grid.ColumnDefinitions>
        <Border x:Name="ToastIconShell" Grid.Column="0" Width="26" Height="26" CornerRadius="7" Background="#102B3F" BorderBrush="#22D3EE" BorderThickness="1" VerticalAlignment="Top">
          <TextBlock x:Name="ToastIcon" Text="✓" Foreground="#22D3EE" FontSize="13" FontWeight="Bold" HorizontalAlignment="Center" VerticalAlignment="Center"/>
        </Border>
        <StackPanel Grid.Column="1">
          <TextBlock x:Name="ToastTitle" Text="Hinweis" Foreground="#DDE6F0" FontFamily="Rajdhani, Segoe UI Semibold, Segoe UI" FontSize="16" FontWeight="Bold"/>
          <TextBlock x:Name="ToastMessage" Text="" Foreground="#8FA3BE" FontFamily="DM Sans, Segoe UI" FontSize="11" TextWrapping="Wrap" Margin="0,2,0,0"/>
        </StackPanel>
      </Grid>
    </Border>
  </Grid>
</Window>
"@
$reader = New-Object System.Xml.XmlNodeReader $xaml
$script:Window = [Windows.Markup.XamlReader]::Load($reader)

try {
  Add-Type @"
using System;
using System.Runtime.InteropServices;
public static class CrimsonDwmTitlebar {
  [DllImport("dwmapi.dll")]
  public static extern int DwmSetWindowAttribute(IntPtr hwnd, int attr, ref int attrValue, int attrSize);
}
"@
} catch {}

function Set-CrimsonTitlebarTheme() { Set-CrimsonTitlebarThemeForWindow $script:Window }

$script:Window.Add_SourceInitialized({ Set-CrimsonTitlebarTheme })
function Ui([string]$name) { return $script:Window.FindName($name) }

$script:LogBox = Ui 'LogBox'
$script:ZipText = Ui 'ZipText'
$script:StatusText = Ui 'StatusText'
$script:StatusPill = Ui 'StatusPill'
$script:DeployButton = Ui 'DeployButton'
$script:PickZipButton = Ui 'PickZipButton'
$script:OpenLogsButton = Ui 'OpenLogsButton'
$script:ClearLogsButton = Ui 'ClearLogsButton'
$script:ServerList = Ui 'ServerList'
$script:LogPathText = Ui 'LogPathText'
$script:DropZone = Ui 'DropZone'
$script:LogoImage = Ui 'LogoImage'
$script:PickUpdateButton = Ui 'PickUpdateButton'
$script:InstallUpdateButton = Ui 'InstallUpdateButton'
$script:UpdateText = Ui 'UpdateText'
$script:VersionText = Ui 'VersionText'
$script:LastUpdateText = Ui 'LastUpdateText'
$script:PreflightButton = Ui 'PreflightButton'
$script:RollbackButton = Ui 'RollbackButton'
$script:HistoryButton = Ui 'HistoryButton'
$script:ExportLogsButton = Ui 'ExportLogsButton'
$script:ServerManagerButton = Ui 'ServerManagerButton'
$script:RefreshServerStatusButton = Ui 'RefreshServerStatusButton'
$script:CloudBackupButton = Ui 'CloudBackupButton'
$script:RestoreBackupButton = Ui 'RestoreBackupButton'
$script:SettingsButton = Ui 'SettingsButton'
$script:CancelButton = Ui 'CancelButton'
$script:StepText = Ui 'StepText'
$script:StepProgress = Ui 'StepProgress'
$script:LogContainer = Ui 'LogContainer'
$script:ToggleLogButton = Ui 'ToggleLogButton'
$script:SelectedServerSummary = Ui 'SelectedServerSummary'
$script:SelectedZipSummary = Ui 'SelectedZipSummary'
$script:LogSummaryText = Ui 'LogSummaryText'
$script:StatusPercentText = Ui 'StatusPercentText'
$script:ToastHost = Ui 'ToastHost'
$script:ToastTitle = Ui 'ToastTitle'
$script:ToastMessage = Ui 'ToastMessage'
$script:ToastIcon = Ui 'ToastIcon'
$script:ToastIconShell = Ui 'ToastIconShell'
$script:StageBadges = @(
  @{ Name = 'ZIP'; Border = (Ui 'StageZip'); Threshold = 10 },
  @{ Name = 'Check'; Border = (Ui 'StageCheck'); Threshold = 18 },
  @{ Name = 'Upload'; Border = (Ui 'StageUpload'); Threshold = 30 },
  @{ Name = 'Build'; Border = (Ui 'StageBuild'); Threshold = 52 },
  @{ Name = 'Health'; Border = (Ui 'StageHealth'); Threshold = 92 },
  @{ Name = 'Done'; Border = (Ui 'StageDone'); Threshold = 100 }
)

$script:LogDocument = [Windows.Documents.FlowDocument]::new()
$script:LogDocument.PagePadding = [Windows.Thickness]::new(0)
$script:LogDocument.FontFamily = [Windows.Media.FontFamily]::new('JetBrains Mono, Cascadia Mono, Consolas')
$script:LogDocument.FontSize = 9.5
$script:LogDocument.LineHeight = 15
$script:LogBox.Document = $script:LogDocument

function New-Brush([string]$hex) {
  return [Windows.Media.SolidColorBrush]::new([Windows.Media.ColorConverter]::ConvertFromString($hex))
}

function Get-LogBrush([string]$line) {
  if ($line -match '(?i)^Permissions-Policy:|^Content-Security-Policy:|^Referrer-Policy:|^X-Content-Type-Options:') { return New-Brush '#91A8BE' }
  if ($line -match '(?i)^Maximale Laufzeit:|läuft seit|Heartbeat|TCP Timeout|TCP Vorprüfung.*Warnung') { return New-Brush '#91A8BE' }
  if ($line -match '(?i)FEHLER|Deploy Status:\s*failed|failed|failure|Exit Code|nicht gefunden|fehlgeschlagen|Timeout nach|Abbruch nach|Permission denied|Access denied|Host key|SCP Upload fehlgeschlagen|Authentifizierung fehlgeschlagen') { return New-Brush '#FB7185' }
  if ($line -match '(?i)success|erfolgreich|abgeschlossen|bereit|CRIMSON_SSH_OK|online') { return New-Brush '#4ADE80' }
  if ($line -match '^(>\s|STDERR:)' -or $line -match '(?i)ssh\.exe|scp\.exe|bash -s|Remote Ziel|Private Key|TCP|Verbindungstest') { return New-Brush '#67E8F9' }
  if ($line -match '(?i)Deploy|Upload|ZIP|Server gewählt|Pflichtprüfung|Backup|rsync|npm|PM2|Status') { return New-Brush '#38BDF8' }
  if ($line -match '^\[[0-9]{2}:[0-9]{2}:[0-9]{2}\]') { return New-Brush '#A7F3D0' }
  return New-Brush '#D9ECFF'
}

function Write-Utf8Line([string]$path, [string]$line) {
  if ([string]::IsNullOrWhiteSpace($path)) { return }
  $dir = Split-Path -Parent $path
  if (-not [string]::IsNullOrWhiteSpace($dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
  $enc = $script:Utf8NoBom
  if ($null -eq $enc) { $enc = [System.Text.UTF8Encoding]::new($false) }
  [System.IO.File]::AppendAllText($path, $line + [Environment]::NewLine, $enc)
}


function Redact-SensitiveText([string]$text) {
  if ($null -eq $text) { return '' }
  $safe = [string]$text
  try {
    $safe = [regex]::Replace($safe, '(?i)(secret(?:key)?|minioSecretKey|accessSecret|password|token)\s*[:=]\s*([^\s;,]+)', '$1=********')
    $safe = [regex]::Replace($safe, '(?i)(access(?:key)?|minioAccessKey)\s*[:=]\s*([A-Za-z0-9_\-]{8,})', '$1=********')
    $safe = [regex]::Replace($safe, '(?i)(Authorization:\s*)(AWS4-HMAC-SHA256|Bearer|Basic)\s+[^\r\n]+', '$1$2 ********')
    $safe = [regex]::Replace($safe, '(?i)(X-Amz-Signature=)[0-9a-f]+', '$1********')
    $safe = [regex]::Replace($safe, '(?i)(X-Amz-Credential=)[^&\s]+', '$1********')
  } catch {}
  return $safe
}

function Write-AppLog([string]$text) {
  $line = $text -replace "`r", ''
  Write-Utf8Line $script:LogFile ('[' + (Get-Date -Format 'yyyy-MM-dd HH:mm:ss.fff') + '] ' + $line)
}


function Read-SharedLines([string]$path) {
  if ([string]::IsNullOrWhiteSpace($path) -or -not (Test-Path -LiteralPath $path)) { return @() }
  $fs = $null
  $reader = $null
  try {
    $share = [System.IO.FileShare]::ReadWrite -bor [System.IO.FileShare]::Delete
    $fs = [System.IO.File]::Open($path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, $share)
    $reader = [System.IO.StreamReader]::new($fs, $script:Utf8NoBom, $true)
    $content = $reader.ReadToEnd()
    if ([string]::IsNullOrEmpty($content)) { return @() }
    return @((($content -replace "`r", '') -split "`n") | Where-Object { $_ -ne $null -and $_ -ne '' })
  } catch [System.IO.IOException] {
    return $null
  } finally {
    if ($null -ne $reader) { $reader.Dispose() }
    elseif ($null -ne $fs) { $fs.Dispose() }
  }
}

function Get-FeedStyle([string]$line) {
  $style = [ordered]@{
    Key = 'INFO'
    Icon = '•'
    Text = '#DDE6F0'
    Border = '#182A3D'
    Background = '#060B15'
    BadgeBg = '#0A1020'
    BadgeText = '#8FA3BE'
  }
  if ($line -match '(?i)^Permissions-Policy:|^Content-Security-Policy:|^Referrer-Policy:|^X-Content-Type-Options:|^Maximale Laufzeit:|läuft seit|Heartbeat') {
    $style['Key'] = 'INFO'; $style['Icon'] = '•'; $style['Text'] = '#91A8BE'; $style['Border'] = '#182A3D'; $style['Background'] = '#060B15'; $style['BadgeBg'] = '#0A1020'; $style['BadgeText'] = '#8FA3BE'
  } elseif ($line -match '(?i)TCP Timeout|TCP Vorprüfung.*Warnung') {
    $style['Key'] = 'WARN'; $style['Icon'] = '!'; $style['Text'] = '#FBBF24'; $style['Border'] = '#4B3A13'; $style['Background'] = '#100D06'; $style['BadgeBg'] = '#271D08'; $style['BadgeText'] = '#FBBF24'
  } elseif ($line -match '(?i)FEHLER|Deploy Status:\s*failed|failed|failure|Exit Code|nicht gefunden|fehlgeschlagen|Timeout nach|Abbruch nach|Permission denied|Access denied|Host key|SCP Upload fehlgeschlagen|Authentifizierung fehlgeschlagen') {
    $style['Key'] = 'ERR'; $style['Icon'] = '✕'; $style['Text'] = '#F87171'; $style['Border'] = '#45202A'; $style['Background'] = '#0D0710'; $style['BadgeBg'] = '#2A0D13'; $style['BadgeText'] = '#F87171'
  } elseif ($line -match '(?i)WARNUNG|warning|nicht eindeutig|Fallback|Legacy') {
    $style['Key'] = 'WARN'; $style['Icon'] = '!'; $style['Text'] = '#FBBF24'; $style['Border'] = '#4B3A13'; $style['Background'] = '#100D06'; $style['BadgeBg'] = '#271D08'; $style['BadgeText'] = '#FBBF24'
  } elseif ($line -match '(?i)success|erfolgreich|abgeschlossen|bereit|online|geladen|gespeichert|validierung erfolgreich|Upload abgeschlossen') {
    $style['Key'] = 'OK'; $style['Icon'] = '✓'; $style['Text'] = '#34D399'; $style['Border'] = '#164638'; $style['Background'] = '#06110D'; $style['BadgeBg'] = '#092017'; $style['BadgeText'] = '#34D399'
  } elseif ($line -match '(?i)^\s*>|ssh\.exe|scp\.exe|bash -s|Remote Ziel|Private Key|TCP|Verbindung|SCP|SSH') {
    $style['Key'] = 'SSH'; $style['Icon'] = '↔'; $style['Text'] = '#67E8F9'; $style['Border'] = '#16465C'; $style['Background'] = '#061019'; $style['BadgeBg'] = '#082433'; $style['BadgeText'] = '#22D3EE'
  } elseif ($line -match '(?i)Deploy|Upload|ZIP|Server gewählt|Backup|npm|PM2|Build|Health|Status') {
    $style['Key'] = 'ACT'; $style['Icon'] = '↯'; $style['Text'] = '#38BDF8'; $style['Border'] = '#143A55'; $style['Background'] = '#06101A'; $style['BadgeBg'] = '#082033'; $style['BadgeText'] = '#38BDF8'
  }
  return $style
}

function Add-LiveFeedLine([string]$line) {
  $style = Get-FeedStyle $line
  $row = [Windows.Controls.Border]::new()
  $row.CornerRadius = [Windows.CornerRadius]::new(8)
  $row.BorderThickness = [Windows.Thickness]::new(1)
  $row.BorderBrush = New-Brush ([string]($style['Border']))
  $row.Background = New-Brush ([string]($style['Background']))
  $row.Padding = [Windows.Thickness]::new(10,7,10,7)
  $row.Margin = [Windows.Thickness]::new(0,0,0,6)

  $grid = [Windows.Controls.Grid]::new()
  foreach ($width in @('58','32','*','54')) {
    $col = [Windows.Controls.ColumnDefinition]::new()
    if ($width -eq '*') { $col.Width = [Windows.GridLength]::new(1, [Windows.GridUnitType]::Star) }
    else { $col.Width = [Windows.GridLength]::new([double]$width) }
    $grid.ColumnDefinitions.Add($col) | Out-Null
  }

  $time = [Windows.Controls.TextBlock]::new()
  $time.Text = (Get-Date -Format 'HH:mm:ss')
  $time.Foreground = New-Brush '#4A5E7A'
  $time.FontFamily = [Windows.Media.FontFamily]::new('JetBrains Mono, Cascadia Mono, Consolas')
  $time.FontSize = 9.5
  $time.VerticalAlignment = [Windows.VerticalAlignment]::Center
  [Windows.Controls.Grid]::SetColumn($time,0)
  $grid.Children.Add($time) | Out-Null

  $iconWrap = [Windows.Controls.Border]::new()
  $iconWrap.Width = 24
  $iconWrap.Height = 24
  $iconWrap.CornerRadius = [Windows.CornerRadius]::new(6)
  $iconWrap.Background = New-Brush '#0A1020'
  $iconWrap.BorderBrush = New-Brush ([string]($style['Border']))
  $iconWrap.BorderThickness = [Windows.Thickness]::new(1)
  $iconWrap.VerticalAlignment = [Windows.VerticalAlignment]::Center
  $icon = [Windows.Controls.TextBlock]::new()
  $icon.Text = [string]($style['Icon'])
  $icon.Foreground = New-Brush ([string]($style['Text']))
  $icon.FontSize = 12
  $icon.FontWeight = [Windows.FontWeights]::Bold
  $icon.HorizontalAlignment = [Windows.HorizontalAlignment]::Center
  $icon.VerticalAlignment = [Windows.VerticalAlignment]::Center
  $iconWrap.Child = $icon
  [Windows.Controls.Grid]::SetColumn($iconWrap,1)
  $grid.Children.Add($iconWrap) | Out-Null

  $msg = [Windows.Controls.TextBlock]::new()
  $msg.Text = $line
  $msg.Foreground = New-Brush ([string]($style['Text']))
  $msg.FontFamily = [Windows.Media.FontFamily]::new('JetBrains Mono, Cascadia Mono, Consolas')
  $msg.FontSize = 10
  $msg.FontWeight = [Windows.FontWeights]::SemiBold
  $msg.TextWrapping = [Windows.TextWrapping]::Wrap
  $msg.VerticalAlignment = [Windows.VerticalAlignment]::Center
  $msg.Margin = [Windows.Thickness]::new(8,0,12,0)
  [Windows.Controls.Grid]::SetColumn($msg,2)
  $grid.Children.Add($msg) | Out-Null

  $badge = [Windows.Controls.Border]::new()
  $badge.CornerRadius = [Windows.CornerRadius]::new(4)
  $badge.Background = New-Brush ([string]($style['BadgeBg']))
  $badge.BorderBrush = New-Brush ([string]($style['Border']))
  $badge.BorderThickness = [Windows.Thickness]::new(1)
  $badge.Padding = [Windows.Thickness]::new(6,2,6,2)
  $badge.HorizontalAlignment = [Windows.HorizontalAlignment]::Right
  $badge.VerticalAlignment = [Windows.VerticalAlignment]::Center
  $bt = [Windows.Controls.TextBlock]::new()
  $bt.Text = [string]($style['Key'])
  $bt.Foreground = New-Brush ([string]($style['BadgeText']))
  $bt.FontFamily = [Windows.Media.FontFamily]::new('JetBrains Mono, Cascadia Mono, Consolas')
  $bt.FontSize = 9
  $bt.FontWeight = [Windows.FontWeights]::Bold
  $badge.Child = $bt
  [Windows.Controls.Grid]::SetColumn($badge,3)
  $grid.Children.Add($badge) | Out-Null

  $row.Child = $grid
  $container = [Windows.Documents.BlockUIContainer]::new($row)
  $container.Margin = [Windows.Thickness]::new(0)
  $script:LogDocument.Blocks.Add($container)
  while ($script:LogDocument.Blocks.Count -gt 320) {
    $script:LogDocument.Blocks.Remove($script:LogDocument.Blocks.FirstBlock)
  }
}

function Add-UiLog([string]$text) {
  if ($null -eq $text) { return }
  $clean = (Redact-SensitiveText (($text -replace "\x1b\[[0-9;?]*[ -/]*[@-~]", '') -replace "`r", ''))
  if ([string]::IsNullOrWhiteSpace($clean)) { return }
  Write-AppLog $clean
  foreach ($line in ($clean -split "`n")) {
    if ([string]::IsNullOrWhiteSpace($line)) { continue }
    Add-LiveFeedLine $line
    if ($script:LogSummaryText) { $script:LogSummaryText.Text = $line }
    try { Update-ProgressFromLine $line } catch {}
  }
  $script:LogBox.ScrollToEnd()
}

function Set-Status([string]$text, [string]$mode) {
  $script:StatusText.Text = $text
  switch ($mode) {
    'running' {
      $script:StatusPill.Background = [Windows.Media.SolidColorBrush]::new([Windows.Media.ColorConverter]::ConvertFromString('#102B3F'))
      $script:StatusPill.BorderBrush = [Windows.Media.SolidColorBrush]::new([Windows.Media.ColorConverter]::ConvertFromString('#22D3EE'))
      if ($script:StatusText) { $script:StatusText.Foreground = New-Brush '#67E8F9' }
    }
    'error' {
      $script:StatusPill.Background = [Windows.Media.SolidColorBrush]::new([Windows.Media.ColorConverter]::ConvertFromString('#451A1A'))
      $script:StatusPill.BorderBrush = [Windows.Media.SolidColorBrush]::new([Windows.Media.ColorConverter]::ConvertFromString('#FF5A7A'))
      if ($script:StatusText) { $script:StatusText.Foreground = New-Brush '#FB7185' }
    }
    'success' {
      $script:StatusPill.Background = [Windows.Media.SolidColorBrush]::new([Windows.Media.ColorConverter]::ConvertFromString('#0E3A27'))
      $script:StatusPill.BorderBrush = [Windows.Media.SolidColorBrush]::new([Windows.Media.ColorConverter]::ConvertFromString('#22C55E'))
      if ($script:StatusText) { $script:StatusText.Foreground = New-Brush '#34D399' }
    }
    default {
      $script:StatusPill.Background = [Windows.Media.SolidColorBrush]::new([Windows.Media.ColorConverter]::ConvertFromString('#07111D'))
      $script:StatusPill.BorderBrush = [Windows.Media.SolidColorBrush]::new([Windows.Media.ColorConverter]::ConvertFromString('#24506D'))
      if ($script:StatusText) { $script:StatusText.Foreground = New-Brush '#8FA3BE' }
    }
  }
}


function Show-CrimsonToast([string]$title, [string]$message, [string]$mode = 'info') {
  try {
    if ($null -eq $script:ToastHost) { return }
    $script:ToastTitle.Text = $title
    $script:ToastMessage.Text = $message
    $border = '#4722D3EE'; $bg = '#102B3F'; $fg = '#22D3EE'; $icon = 'i'
    switch ($mode) {
      'success' { $border = '#3310B981'; $bg = '#092017'; $fg = '#34D399'; $icon = '✓' }
      'error' { $border = '#55EF4444'; $bg = '#2A0D13'; $fg = '#F87171'; $icon = '!' }
      'warn' { $border = '#55F59E0B'; $bg = '#271D08'; $fg = '#FBBF24'; $icon = '!' }
      default { $border = '#4722D3EE'; $bg = '#102B3F'; $fg = '#22D3EE'; $icon = 'i' }
    }
    $script:ToastHost.BorderBrush = New-Brush $border
    $script:ToastIconShell.BorderBrush = New-Brush $fg
    $script:ToastIconShell.Background = New-Brush $bg
    $script:ToastIcon.Foreground = New-Brush $fg
    $script:ToastIcon.Text = $icon
    $script:ToastHost.Visibility = [Windows.Visibility]::Visible
    if ($null -ne $script:ToastTimer) { try { $script:ToastTimer.Stop() } catch {} }
    $script:ToastTimer = [Windows.Threading.DispatcherTimer]::new()
    $script:ToastTimer.Interval = [TimeSpan]::FromSeconds(4)
    $script:ToastTimer.Add_Tick({
      try { $script:ToastTimer.Stop(); $script:ToastHost.Visibility = [Windows.Visibility]::Collapsed } catch {}
    })
    $script:ToastTimer.Start()
  } catch {}
}

function Safe-FileName([string]$name) {
  if ([string]::IsNullOrWhiteSpace($name)) { return '' }
  $file = [IO.Path]::GetFileName($name)
  if ([string]::IsNullOrWhiteSpace($file)) { return '' }
  return ($file -replace '[^a-zA-Z0-9._-]', '_')
}

function Detect-Kind([string]$fileName) {
  $name = [IO.Path]::GetFileName($fileName)
  if ($name -match '^crimson-hub-(?:v\d+(?:-\d+)?|\d+\.\d+\.\d+(?:[-+][0-9A-Za-z._-]+)?)\.zip$') { return 'hub' }
  if ($name -match '^crimson-acp-(?:v\d+(?:-\d+)?|\d+\.\d+\.\d+(?:[-+][0-9A-Za-z._-]+)?)\.zip$') { return 'acp' }
  return $null
}


function Normalize-DeployKind($value) {
  try {
    foreach ($item in @($value)) {
      $text = ([string]$item).Trim().ToLowerInvariant()
      if ($text -eq 'hub') { return 'hub' }
      if ($text -eq 'acp') { return 'acp' }
    }
  } catch {}
  return ''
}

function Version-FromFile([string]$fileName) {
  if ([string]::IsNullOrWhiteSpace($fileName)) { return 'manual' }
  $name = [IO.Path]::GetFileName($fileName)
  if ([string]::IsNullOrWhiteSpace($name)) { return 'manual' }
  $m = [regex]::Match($name, '^crimson-(?:hub|acp)-(\d+\.\d+\.\d+)(?:[-+][0-9A-Za-z._-]+)?\.zip$', 'IgnoreCase')
  if ($m.Success) { return $m.Groups[1].Value.ToLowerInvariant() }
  $legacy = [regex]::Match($name, '^crimson-(?:hub|acp)-(v\d+(?:-\d+)?)\.zip$', 'IgnoreCase')
  if ($legacy.Success) { return $legacy.Groups[1].Value.ToLowerInvariant() }
  return 'manual'
}

function Convert-VersionParts([string]$version) {
  if ([string]::IsNullOrWhiteSpace($version) -or $version -eq 'manual') { return @(-1,-1,-1,0,'') }
  $sem = [regex]::Match($version, '^(\d+)\.(\d+)\.(\d+)(?:-([0-9A-Za-z.-]+))?(?:\+[0-9A-Za-z.-]+)?$', 'IgnoreCase')
  if ($sem.Success) {
    $pre = ''
    if ($sem.Groups[4].Success) { $pre = $sem.Groups[4].Value }
    return @([int]$sem.Groups[1].Value, [int]$sem.Groups[2].Value, [int]$sem.Groups[3].Value, $(if([string]::IsNullOrWhiteSpace($pre)){1}else{0}), $pre)
  }
  $legacy = [regex]::Match($version, '^v(\d+)(?:-(\d+))?$', 'IgnoreCase')
  if ($legacy.Success) {
    $minor = [int]$legacy.Groups[1].Value
    $patch = 0
    if ($legacy.Groups.Count -gt 2 -and $legacy.Groups[2].Success) { $patch = [int]$legacy.Groups[2].Value }
    return @(0, $minor, $patch, 1, '')
  }
  return @(-1,-1,-1,0,'')
}

function Compare-CrimsonVersion([string]$a, [string]$b) {
  $pa = Convert-VersionParts $a
  $pb = Convert-VersionParts $b
  for ($i = 0; $i -lt 4; $i++) {
    if ([int]$pa[$i] -lt [int]$pb[$i]) { return -1 }
    if ([int]$pa[$i] -gt [int]$pb[$i]) { return 1 }
  }
  $preA = [string]$pa[4]
  $preB = [string]$pb[4]
  return [string]::Compare($preA, $preB, $true)
}

function Get-ServerLabel($srv) {
  if ($null -eq $srv) { return '' }
  if ($srv.PSObject.Properties.Name -contains 'label' -and $srv.label) { return [string]$srv.label }
  if ($srv.PSObject.Properties.Name -contains 'id' -and $srv.id) { return [string]$srv.id }
  return 'Server'
}

function Get-ServerKind($srv) {
  if ($null -eq $srv) { return '' }
  if ($srv.PSObject.Properties.Name -contains 'kind') { return Normalize-DeployKind $srv.PSObject.Properties['kind'].Value }
  if ($srv.PSObject.Properties.Name -contains 'type') { return Normalize-DeployKind $srv.PSObject.Properties['type'].Value }
  return ''
}

function Get-ServerHost($srv) {
  if ($null -eq $srv) { return '' }
  if ($srv.PSObject.Properties.Name -contains 'host' -and $srv.host) { return [string]$srv.host }
  return ''
}

function Resolve-ServerKeyPath($srv) {
  if ($null -eq $srv) { return '' }
  $path = ''
  if ($srv.PSObject.Properties.Name -contains 'privateKeyPath' -and $srv.privateKeyPath) { $path = [string]$srv.privateKeyPath }
  return Resolve-KeyPath $path $script:Root
}

function Get-ServerPrimaryKey($srv) {
  $keys = @(Get-ServerIdentityKeys $srv)
  if ($keys.Count -gt 0) { return [string]$keys[0] }
  return (Get-ServerLabel $srv).ToLowerInvariant()
}


function Get-ObjectPropertyValue($obj, [string]$name, $default = '') {
  try {
    if ($null -eq $obj -or [string]::IsNullOrWhiteSpace($name)) { return $default }
    if ($obj.PSObject.Properties.Name -contains $name) {
      $value = $obj.PSObject.Properties[$name].Value
      if ($null -ne $value) { return $value }
    }
  } catch {}
  return $default
}

function Get-ObjectPropertyString($obj, [string]$name, [string]$default = '') {
  $value = Get-ObjectPropertyValue $obj $name $default
  if ($null -eq $value) { return $default }
  return [string]$value
}


function Get-HealthStatusFromValue($value) {
  try {
    if ($null -eq $value) { return '' }
    if ($value.PSObject -and ($value.PSObject.Properties.Name -contains 'online')) {
      return $(if ([bool]$value.online) { 'online' } else { 'offline' })
    }
    $text = ([string]$value).Trim().ToLowerInvariant()
    if ($text -eq 'true') { return 'online' }
    if ($text -eq 'false') { return 'offline' }
    if ($text -match 'online') { return 'online' }
    if ($text -match 'offline') { return 'offline' }
    return $text
  } catch { return '' }
}

function New-HealthRecord([string]$status, [string]$method = 'mixed') {
  return [pscustomobject]@{
    online = ($status -eq 'online')
    checkedAt = (Get-Date).ToString('s')
    method = $method
  }
}

function Load-ServerHealthState() {
  try {
    if (-not (Test-Path -LiteralPath $script:ServerHealthFile)) { return }
    $raw = Get-Content -LiteralPath $script:ServerHealthFile -Raw -Encoding UTF8
    if ([string]::IsNullOrWhiteSpace($raw)) { return }
    $obj = $raw | ConvertFrom-Json
    $script:ServerHealth.Clear()
    foreach ($prop in $obj.PSObject.Properties) {
      if ($prop.Name -and $null -ne $prop.Value) { $script:ServerHealth[[string]$prop.Name] = $prop.Value }
    }
  } catch { try { Add-UiLog ('WARNUNG: Online Status Cache konnte nicht geladen werden: ' + $_.Exception.Message) } catch {} }
}

function Save-ServerHealthState() {
  try {
    $obj = [ordered]@{}
    foreach ($key in $script:ServerHealth.Keys) {
      if ([string]::IsNullOrWhiteSpace([string]$key)) { continue }
      $value = $script:ServerHealth[$key]
      if ($value.PSObject -and ($value.PSObject.Properties.Name -contains 'online')) { $obj[[string]$key] = $value }
      else { $obj[[string]$key] = New-HealthRecord (Get-HealthStatusFromValue $value) 'legacy' }
    }
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $script:ServerHealthFile) | Out-Null
    [System.IO.File]::WriteAllText($script:ServerHealthFile, ($obj | ConvertTo-Json -Depth 8), $script:Utf8NoBom)
  } catch { try { Add-UiLog ('WARNUNG: Online Status Cache konnte nicht gespeichert werden: ' + $_.Exception.Message) } catch {} }
}

function Get-ServerHealthStatus($srv) {
  try {
    $keys = @(Get-ServerIdentityKeys $srv)
    foreach ($k in $keys) {
      if ($script:ServerHealth.ContainsKey($k) -and (Get-HealthStatusFromValue $script:ServerHealth[$k]) -eq 'online') { return 'online' }
    }
    foreach ($k in $keys) {
      if ($script:ServerHealth.ContainsKey($k) -and (Get-HealthStatusFromValue $script:ServerHealth[$k]) -eq 'offline') { return 'offline' }
    }
  } catch {}
  return 'offline'
}

function Get-KeyStatusText($srv) {
  try {
    $key = Resolve-ServerKeyPath $srv
    if ([string]::IsNullOrWhiteSpace($key)) { return 'Key fehlt' }
    if (Test-Path -LiteralPath $key) { return 'Key OK' }
    return 'Key fehlt'
  } catch { return 'Key Fehler' }
}

function Load-AppSettings() {
  $defaults = [ordered]@{
    autoHealthCheck = $true
    autoCollapseLog = $true
    autoHealthAfterDeploy = $true
    autoConfigBackupAfterDeploy = $false
    keepHistoryDays = 180
    keepBackupCount = 10
    premiumGlow = $true
    backupFolder = ''
  }
  try {
    if (Test-Path -LiteralPath $script:SettingsFile) {
      $raw = Get-Content -LiteralPath $script:SettingsFile -Raw -Encoding UTF8
      if (-not [string]::IsNullOrWhiteSpace($raw)) {
        $obj = $raw | ConvertFrom-Json
        foreach ($prop in $obj.PSObject.Properties) { $defaults[$prop.Name] = $prop.Value }
      }
    }
  } catch {}
  foreach ($legacySetting in @('cloudBackupMode','minioEndpoint','minioBucket','minioRegion','minioPrefix','minioAccessKey','minioSecretKey','minioUseSsl')) {
    try { if ($defaults.Contains($legacySetting)) { [void]$defaults.Remove($legacySetting) } } catch {}
  }
  $script:AppSettings = $defaults
  try {
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $script:SettingsFile) | Out-Null
    [System.IO.File]::WriteAllText($script:SettingsFile, (($script:AppSettings | ConvertTo-Json -Depth 8)), $script:Utf8NoBom)
  } catch {}
  return $script:AppSettings
}

function Save-AppSettings() {
  try {
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $script:SettingsFile) | Out-Null
    [System.IO.File]::WriteAllText($script:SettingsFile, (($script:AppSettings | ConvertTo-Json -Depth 8)), $script:Utf8NoBom)
  } catch { Add-UiLog ('FEHLER: Einstellungen konnten nicht gespeichert werden: ' + $_.Exception.Message) }
}

function Get-AppSettingBool([string]$name, [bool]$defaultValue) {
  try {
    if ($null -eq $script:AppSettings) { Load-AppSettings | Out-Null }
    if ($script:AppSettings.Contains($name)) { return [bool]$script:AppSettings[$name] }
  } catch {}
  return $defaultValue
}

function Get-AppSettingInt([string]$name, [int]$defaultValue, [int]$minValue) {
  try {
    if ($null -eq $script:AppSettings) { Load-AppSettings | Out-Null }
    if ($script:AppSettings.Contains($name)) {
      $v = $defaultValue
      [void][int]::TryParse(([string]$script:AppSettings[$name]), [ref]$v)
      if ($v -lt $minValue) { $v = $minValue }
      return $v
    }
  } catch {}
  return $defaultValue
}

function Get-AppSettingString([string]$name, [string]$defaultValue) {
  try {
    if ($null -eq $script:AppSettings) { Load-AppSettings | Out-Null }
    if ($script:AppSettings.Contains($name)) { return [string]$script:AppSettings[$name] }
  } catch {}
  return $defaultValue
}

function Shell-Quote([string]$value) {
  return "'" + ($value -replace "'", "'\''") + "'"
}

function Build-HubScript([string]$fileName) {
  $version = Version-FromFile $fileName
  $baseName = $fileName -replace '\.zip$', ''
  $remoteZip = "/tmp/$fileName"
  $workDir = "/tmp/$baseName"
  $zipQ = Shell-Quote $remoteZip
  $workQ = Shell-Quote $workDir
  $versionQ = Shell-Quote $version
  $healthBlock = @'
log "Health Check Hub"
CODE=$(curl -sS -o /dev/null -w "%{http_code}" --max-time 20 https://next.cr1ms0n.xyz/ || true)
case "$CODE" in 2*|3*) log "Health Check erfolgreich: HTTP $CODE" ;; *) fail "Health Check fehlgeschlagen: HTTP $CODE" ;; esac
curl -I https://next.cr1ms0n.xyz/media-cloud || true
curl -I https://next.cr1ms0n.xyz/notes || true
'@
  if (-not (Get-AppSettingBool 'autoHealthAfterDeploy' $true)) { $healthBlock = 'log "Health Check übersprungen (Einstellung)"' }
@"
set -Eeuo pipefail
export DEBIAN_FRONTEND=noninteractive
ZIP=$zipQ
WORK=$workQ
VERSION=$versionQ
APP=/opt/cr1ms0n-next

log(){ printf '\n[%s] %s\n' "`$(date +%H:%M:%S)" "`$*"; }
fail(){ echo "FEHLER: `$*"; exit 1; }

log "Hub Deploy startet"
log "ZIP: `$ZIP"
log "WORK: `$WORK"
command -v unzip >/dev/null || fail "unzip fehlt"
command -v rsync >/dev/null || fail "rsync fehlt"
command -v npm >/dev/null || fail "npm fehlt"
[ -f "`$ZIP" ] || fail "ZIP fehlt: `$ZIP"
[ -d "`$APP" ] || fail "Hub App fehlt: `$APP"

log "Entpacke nach /tmp"
rm -rf "`$WORK"
mkdir -p "`$WORK"
unzip -o "`$ZIP" -d "`$WORK"

log "Pflichtprüfung Hub Paket"
ls -la "`$WORK/package.json"
ls -la "`$WORK/prisma/schema.prisma"
ls -la "`$WORK/src"
[ -f "`$WORK/package.json" ] || fail "package.json fehlt im Paket"
[ -f "`$WORK/prisma/schema.prisma" ] || fail "prisma/schema.prisma fehlt im Paket"
[ -d "`$WORK/src" ] || fail "src Ordner fehlt im Paket"
node -e "JSON.parse(require('fs').readFileSync(process.argv[1], 'utf8'));" "`$WORK/package.json" || fail "package.json ist ungültig"

log "Backup erstellen"
BACKUP="/opt/cr1ms0n-next-backup-`$VERSION-`$(date +%Y%m%d-%H%M%S)"
cp -a "`$APP" "`$BACKUP"
log "Backup: `$BACKUP"

log "Lockfile Schutz vorbereiten"
LOCK_BACKUP="/tmp/crimson-package-lock-`$VERSION.json"
[ -f "`$APP/package-lock.json" ] && cp -a "`$APP/package-lock.json" "`$LOCK_BACKUP" || true

log "rsync Hub mit --delete nach Pflichtprüfung"
rsync -av --delete \
  --exclude='.env' \
  --exclude='.env.local' \
  --exclude='node_modules/' \
  --exclude='.next/' \
  --exclude='storage/' \
  --exclude='uploads/' \
  --exclude='backups/' \
  --exclude='logs/' \
  --exclude='package-lock.json' \
  "`$WORK"/ "`$APP"/

cd "`$APP"
[ -f "`$APP/package-lock.json" ] || { [ -f "`$LOCK_BACKUP" ] && cp -a "`$LOCK_BACKUP" "`$APP/package-lock.json"; }
printf 'registry=https://registry.npmjs.org/\nfund=false\naudit=false\n' > .npmrc
npm config set registry https://registry.npmjs.org/ || true
log "npm install"
npm install --registry=https://registry.npmjs.org/
log "Datenbank Schema sicherstellen"
npx prisma db push
log "Prisma Client generieren"
npx prisma generate
log "Hub Build"
npm run build
log "Lockfile nach Next Patch sicherstellen"
npm install --registry=https://registry.npmjs.org/
log "Service Neustart"
systemctl restart cr1ms0n-next.service
sleep 3
log "Status"
systemctl status cr1ms0n-next.service --no-pager || true
systemctl is-active --quiet cr1ms0n-next.service || fail "Hub Service ist nach Restart nicht aktiv. Backup liegt bei `$BACKUP"
$healthBlock
log "Bereinigung Hub"
rm -rf /tmp/crimson-hub-v*
rm -f /tmp/crimson-hub-v*.zip
npm cache clean --force || true
journalctl --vacuum-time=7d || true
cd /opt
ls -dt /opt/cr1ms0n-next-backup-* 2>/dev/null | tail -n +3 | xargs -r rm -rf
du -h --max-depth=1 /opt | sort -hr | head -20
df -h
log "Hub Deploy fertig"
"@
}

function Build-AcpScript([string]$fileName) {
  $version = Version-FromFile $fileName
  $baseName = $fileName -replace '\.zip$', ''
  $remoteZip = "/tmp/$fileName"
  $workDir = "/tmp/$baseName"
  $zipQ = Shell-Quote $remoteZip
  $workQ = Shell-Quote $workDir
  $versionQ = Shell-Quote $version
  $healthBlock = @'
log "Health Check ACP"
CODE=$(curl -sS -o /dev/null -w "%{http_code}" --max-time 20 https://acp.cr1ms0n.xyz/ || true)
case "$CODE" in 2*|3*) log "Health Check erfolgreich: HTTP $CODE" ;; *) fail "Health Check fehlgeschlagen: HTTP $CODE" ;; esac
curl -s https://acp.cr1ms0n.xyz/api/auth/hub/status || true
printf '\n'
curl -s https://acp.cr1ms0n.xyz/ | grep 'ACP_UI_BUILD' || true
'@
  if (-not (Get-AppSettingBool 'autoHealthAfterDeploy' $true)) { $healthBlock = 'log "Health Check übersprungen (Einstellung)"' }
@"
set -Eeuo pipefail
export DEBIAN_FRONTEND=noninteractive
ZIP=$zipQ
WORK=$workQ
VERSION=$versionQ
APP=/opt/crimson-acp

log(){ printf '\n[%s] %s\n' "`$(date +%H:%M:%S)" "`$*"; }
fail(){ echo "FEHLER: `$*"; exit 1; }

log "ACP Deploy startet"
log "ZIP: `$ZIP"
log "WORK: `$WORK"
command -v unzip >/dev/null || fail "unzip fehlt"
command -v rsync >/dev/null || fail "rsync fehlt"
command -v npm >/dev/null || fail "npm fehlt"
[ -f "`$ZIP" ] || fail "ZIP fehlt: `$ZIP"
[ -d "`$APP" ] || fail "ACP App fehlt: `$APP"

log "Entpacke nach /tmp"
rm -rf "`$WORK"
mkdir -p "`$WORK"
unzip -o "`$ZIP" -d "`$WORK"

log "Pflichtprüfung ACP Paket"
ls -la "`$WORK/server.js"
ls -la "`$WORK/package.json"
ls -la "`$WORK/public"
ls -la "`$WORK/lib"
[ -f "`$WORK/server.js" ] || fail "server.js fehlt im Paket"
[ -f "`$WORK/package.json" ] || fail "package.json fehlt im Paket"
[ -d "`$WORK/public" ] || fail "public Ordner fehlt im Paket"
[ -d "`$WORK/lib" ] || fail "lib Ordner fehlt im Paket"
node -e "JSON.parse(require('fs').readFileSync(process.argv[1], 'utf8'));" "`$WORK/package.json" || fail "package.json ist ungültig"

log "Backup erstellen"
BACKUP="/opt/crimson-acp-backup-`$VERSION-`$(date +%Y%m%d-%H%M%S)"
cp -a "`$APP" "`$BACKUP"
log "Backup: `$BACKUP"

log "Lockfile Schutz vorbereiten"
LOCK_BACKUP="/tmp/crimson-acp-package-lock-`$VERSION.json"
[ -f "`$APP/package-lock.json" ] && cp -a "`$APP/package-lock.json" "`$LOCK_BACKUP" || true

log "rsync ACP bewusst ohne --delete"
rsync -av \
  --exclude='.env' \
  --exclude='node_modules/' \
  --exclude='runtime/' \
  --exclude='data/' \
  --exclude='uploads/' \
  --exclude='backups/' \
  --exclude='logs/' \
  "`$WORK"/ "`$APP"/

cd "`$APP"
[ -f "`$APP/package-lock.json" ] || { [ -f "`$LOCK_BACKUP" ] && cp -a "`$LOCK_BACKUP" "`$APP/package-lock.json"; }
printf 'registry=https://registry.npmjs.org/\nfund=false\naudit=false\n' > .npmrc
npm config set registry https://registry.npmjs.org/ || true
log "npm install"
npm install --registry=https://registry.npmjs.org/
log "npm run check"
npm run check
log "PM2 Neustart"
pm2 restart crimson-acp --update-env
pm2 save
sleep 3
log "Status"
pm2 status || true
pm2 describe crimson-acp | grep -qi "online" || fail "ACP Prozess ist nach Restart nicht online. Backup liegt bei `$BACKUP"
$healthBlock
log "Bereinigung ACP"
rm -rf /tmp/crimson-acp-v*
rm -f /tmp/crimson-acp-v*.zip
npm cache clean --force || true
pm2 flush || true
journalctl --vacuum-time=7d || true
cd /opt
ls -dt /opt/crimson-acp-backup-* 2>/dev/null | tail -n +3 | xargs -r rm -rf
rm -rf /opt/crimson-acp-broken-*
du -h --max-depth=1 /opt | sort -hr | head -20
df -h
log "ACP Deploy fertig"
"@
}

function Build-DeployScript($kind, [string]$fileName) {
  $kind = Normalize-DeployKind $kind
  if ($kind -eq 'hub') { return Build-HubScript $fileName }
  if ($kind -eq 'acp') { return Build-AcpScript $fileName }
  throw "Unbekannter Deploy Typ: $kind"
}

function Set-ZipFile([string]$path) {
  if ([string]::IsNullOrWhiteSpace($path)) { return }
  if (-not (Test-Path -LiteralPath $path)) { Add-UiLog "FEHLER: Datei nicht gefunden: $path"; return }
  if ([IO.Path]::GetExtension($path).ToLowerInvariant() -ne '.zip') { Add-UiLog 'FEHLER: Bitte eine ZIP Datei auswählen.'; return }
  $script:SelectedZip = $path
  $script:ZipText.Text = [IO.Path]::GetFileName($path)
  if ($script:SelectedZipSummary) { $script:SelectedZipSummary.Text = 'ZIP: ' + [IO.Path]::GetFileName($path) }
  $fileName = Safe-FileName $path
  Add-UiLog "ZIP gewählt: $path"
  $detectedKind = Detect-Kind $fileName
  if (-not [string]::IsNullOrWhiteSpace($detectedKind)) {
    $matched = $false
    foreach ($srv in $script:Servers) {
      if ((Get-ServerKind $srv) -eq $detectedKind) {
        $script:SelectedServer = $srv
        $matched = $true
        Add-UiLog "ZIP Auto Erkennung: $($detectedKind.ToUpperInvariant()) erkannt und passenden Server gewählt: $(Get-ServerLabel $srv)"
        Refresh-ServerButtons
        break
      }
    }
    if (-not $matched) { Add-UiLog "WARNUNG: ZIP Typ $detectedKind erkannt, aber kein passender Server gefunden." }
  }
  if ($null -ne $script:SelectedServer) {
    try { [void](Validate-ZipPackage $path (Get-ServerKind $script:SelectedServer)); Set-ProgressStage 'ZIP validiert' 10 }
    catch { Add-UiLog ('FEHLER: ' + $_.Exception.Message); Set-Status 'ZIP Fehler' 'error'; return }
  }
  Set-Status 'ZIP geladen' 'success'
}



function Get-CrimsonAppIconSource() {
  try {
    if ($script:AppIconSource) { return $script:AppIconSource }
    $ico = Join-Path $script:Root 'assets\app-icon.ico'
    $png = Join-Path $script:Root 'assets\app-icon.png'
    if (Test-Path -LiteralPath $ico) {
      $uri = [System.Uri]::new($ico, [System.UriKind]::Absolute)
      $decoder = [Windows.Media.Imaging.IconBitmapDecoder]::new(
        $uri,
        [Windows.Media.Imaging.BitmapCreateOptions]::PreservePixelFormat,
        [Windows.Media.Imaging.BitmapCacheOption]::OnLoad
      )
      if ($decoder.Frames.Count -gt 0) {
        $frame = $decoder.Frames[0]
        if ($frame.CanFreeze) { $frame.Freeze() }
        $script:AppIconSource = $frame
        return $script:AppIconSource
      }
    }
    if (Test-Path -LiteralPath $png) {
      $uri = [System.Uri]::new($png, [System.UriKind]::Absolute)
      $bmp = [Windows.Media.Imaging.BitmapImage]::new()
      $bmp.BeginInit()
      $bmp.CacheOption = [Windows.Media.Imaging.BitmapCacheOption]::OnLoad
      $bmp.CreateOptions = [Windows.Media.Imaging.BitmapCreateOptions]::IgnoreImageCache
      $bmp.UriSource = $uri
      $bmp.EndInit()
      if ($bmp.CanFreeze) { $bmp.Freeze() }
      $script:AppIconSource = $bmp
      return $script:AppIconSource
    }
  } catch { try { Add-UiLog ('Icon konnte nicht geladen werden: ' + $_.Exception.Message) } catch {} }
  return $null
}

function Set-CrimsonTitlebarThemeForWindow($win) {
  try {
    if ($null -eq $win) { return }
    $helper = [System.Windows.Interop.WindowInteropHelper]::new($win)
    $hwnd = $helper.Handle
    if ($hwnd -eq [IntPtr]::Zero) { return }
    $dark = $true
    try {
      $personalize = Get-ItemProperty -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize' -ErrorAction SilentlyContinue
      if ($null -ne $personalize -and $personalize.PSObject.Properties.Name -contains 'AppsUseLightTheme') {
        $dark = ([int]$personalize.AppsUseLightTheme -eq 0)
      }
    } catch { $dark = $true }
    $darkValue = if ($dark) { 1 } else { 0 }
    foreach ($attr in @(20,19)) { try { [CrimsonDwmTitlebar]::DwmSetWindowAttribute($hwnd, $attr, [ref]$darkValue, 4) | Out-Null } catch {} }
    if ($dark) {
      $caption = 0x000F0704
      $text = 0x00F0E6DD
      try { [CrimsonDwmTitlebar]::DwmSetWindowAttribute($hwnd, 35, [ref]$caption, 4) | Out-Null } catch {}
      try { [CrimsonDwmTitlebar]::DwmSetWindowAttribute($hwnd, 36, [ref]$text, 4) | Out-Null } catch {}
    }
  } catch {}
}

function Apply-CrimsonSubWindowStyle($win) {
  try {
    if ($null -eq $win) { return }
    $icon = Get-CrimsonAppIconSource
    if ($icon) { $win.Icon = $icon }
    $win.FontFamily = [Windows.Media.FontFamily]::new('DM Sans, Segoe UI')
    $win.Background = New-Brush '#04070F'
    $win.Add_SourceInitialized({ param($sender,$e) Set-CrimsonTitlebarThemeForWindow $sender })
  } catch {}
}

function Load-AppIcon() {
  try {
    $icon = Get-CrimsonAppIconSource
    if ($icon) { $script:Window.Icon = $icon }
  } catch {
    try { Add-UiLog ('Icon konnte nicht geladen werden: ' + $_.Exception.Message) } catch {}
  }
}

function Load-Logo() {
  $logo = Join-Path $script:Root 'assets\crimson-wordmark.png'
  if (Test-Path -LiteralPath $logo) {
    $uri = New-Object System.Uri($logo)
    $bmp = New-Object Windows.Media.Imaging.BitmapImage
    $bmp.BeginInit()
    $bmp.CacheOption = [Windows.Media.Imaging.BitmapCacheOption]::OnLoad
    $bmp.UriSource = $uri
    $bmp.EndInit()
    $script:LogoImage.Source = $bmp
  }
}


function Update-SelectedServerSummary() {
  if ($null -eq $script:SelectedServerSummary) { return }
  if ($null -eq $script:SelectedServer) {
    $script:SelectedServerSummary.Text = 'Server: keiner gewählt'
    return
  }
  $port = if ($script:SelectedServer.port) { [int]$script:SelectedServer.port } else { 22 }
  $user = if ($script:SelectedServer.username) { [string]$script:SelectedServer.username } else { 'root' }
  $kindRaw = Get-ServerKind $script:SelectedServer
  $kind = if (-not [string]::IsNullOrWhiteSpace($kindRaw)) { $kindRaw.ToUpperInvariant() } else { '?' }
  $script:SelectedServerSummary.Text = "Server: $($script:SelectedServer.label) · $kind · $user@$($script:SelectedServer.host):$port"
}



function New-LinearBrushVertical([string]$top, [string]$bottom) {
  $brush = New-Object Windows.Media.LinearGradientBrush
  $brush.StartPoint = [Windows.Point]::new(0,0)
  $brush.EndPoint = [Windows.Point]::new(0,1)
  $brush.GradientStops.Add((New-Object Windows.Media.GradientStop -Property @{ Color = [Windows.Media.ColorConverter]::ConvertFromString($top); Offset = 0 })) | Out-Null
  $brush.GradientStops.Add((New-Object Windows.Media.GradientStop -Property @{ Color = [Windows.Media.ColorConverter]::ConvertFromString($bottom); Offset = 1 })) | Out-Null
  return $brush
}

function New-ServerTag([string]$text, [string]$state) {
  $b = New-Object Windows.Controls.Border
  $b.CornerRadius = [Windows.CornerRadius]::new(4)
  $b.BorderThickness = [Windows.Thickness]::new(1)
  $b.Padding = [Windows.Thickness]::new(7,2,7,2)
  $b.Margin = [Windows.Thickness]::new(0,0,5,0)
  $t = New-Object Windows.Controls.TextBlock
  $t.Text = $text
  $t.FontFamily = [Windows.Media.FontFamily]::new('JetBrains Mono, Cascadia Mono, Consolas')
  $t.FontSize = 9
  $t.FontWeight = [Windows.FontWeights]::Medium
  switch ($state) {
    'version' { $b.Background = New-Brush '#0AFFFFFF'; $b.BorderBrush = New-Brush '#1F22D3EE'; $t.Foreground = New-Brush '#8FA3BE' }
    'online'  { $b.Background = New-Brush '#1A10B981'; $b.BorderBrush = New-Brush '#4710B981'; $t.Foreground = New-Brush '#34D399' }
    'offline' { $b.Background = New-Brush '#1AEF4444'; $b.BorderBrush = New-Brush '#47EF4444'; $t.Foreground = New-Brush '#F87171' }
    'key'     { $b.Background = New-Brush '#1406B6D4'; $b.BorderBrush = New-Brush '#1F22D3EE'; $t.Foreground = New-Brush '#22D3EE' }
    default   { $b.Background = New-Brush '#1AEF4444'; $b.BorderBrush = New-Brush '#47EF4444'; $t.Foreground = New-Brush '#F87171' }
  }
  $b.Child = $t
  return $b
}

function Find-ChildByTag($root, [string]$tag) {
  if ($null -eq $root) { return $null }
  try { if ($root.Tag -eq $tag) { return $root } } catch {}
  $count = 0
  try { $count = [Windows.Media.VisualTreeHelper]::GetChildrenCount($root) } catch { $count = 0 }
  for ($i=0; $i -lt $count; $i++) {
    $child = [Windows.Media.VisualTreeHelper]::GetChild($root, $i)
    $found = Find-ChildByTag $child $tag
    if ($null -ne $found) { return $found }
  }
  try {
    foreach ($child in $root.Children) {
      $found = Find-ChildByTag $child $tag
      if ($null -ne $found) { return $found }
    }
  } catch {}
  return $null
}

function New-ServerCardButton($srv) {
  $btn = New-Object Windows.Controls.Button
  $btn.Style = $script:Window.Resources['ServerButtonStyle']
  $btn.Tag = $srv

  $port = if ($srv.port) { [int]$srv.port } else { 22 }
  $user = if ($srv.username) { [string]$srv.username } else { 'root' }
  $kindRaw = Get-ServerKind $srv
  $kind = if (-not [string]::IsNullOrWhiteSpace($kindRaw)) { $kindRaw.ToUpperInvariant() } else { '?' }
  $labelText = if ($srv.label) { [string]$srv.label } else { [string]$srv.id }
  $hostLine = "$kind · $user@$($srv.host):$port"

  $root = New-Object Windows.Controls.Grid
  $root.ClipToBounds = $true
  $line = New-Object Windows.Controls.Border
  $line.Tag = 'ActiveLine'
  $line.Width = 2.5
  $line.HorizontalAlignment = 'Left'
  $line.VerticalAlignment = 'Stretch'
  $line.Background = New-LinearBrushVertical '#22D3EE' '#0891B2'
  $line.Visibility = 'Collapsed'
  $line.Effect = New-Object Windows.Media.Effects.DropShadowEffect -Property @{ Color = [Windows.Media.ColorConverter]::ConvertFromString('#06B6D4'); BlurRadius = 8; ShadowDepth = 0; Opacity = 0.75 }

  $inner = New-Object Windows.Controls.StackPanel
  $inner.Margin = [Windows.Thickness]::new(12,10,12,9)
  $inner.VerticalAlignment = 'Center'

  $top = New-Object Windows.Controls.Grid
  $top.Margin = [Windows.Thickness]::new(0,0,0,8)
  $top.ColumnDefinitions.Add((New-Object Windows.Controls.ColumnDefinition -Property @{ Width = [Windows.GridLength]::new(34) })) | Out-Null
  $top.ColumnDefinitions.Add((New-Object Windows.Controls.ColumnDefinition -Property @{ Width = [Windows.GridLength]::new(1, [Windows.GridUnitType]::Star) })) | Out-Null
  $top.ColumnDefinitions.Add((New-Object Windows.Controls.ColumnDefinition -Property @{ Width = [Windows.GridLength]::new(16) })) | Out-Null

  $iconBorder = New-Object Windows.Controls.Border
  $iconBorder.Width = 26; $iconBorder.Height = 26
  $iconBorder.CornerRadius = [Windows.CornerRadius]::new(6)
  $iconBorder.Background = New-Brush '#1406B6D4'
  $iconBorder.BorderBrush = New-Brush '#1F22D3EE'
  $iconBorder.BorderThickness = [Windows.Thickness]::new(1)
  $iconBorder.HorizontalAlignment = 'Left'
  $iconBorder.VerticalAlignment = 'Center'
  $icon = New-Object Windows.Controls.TextBlock
  $icon.Text = if ($kindRaw -eq 'hub') { [string][char]0xE774 } elseif ($kindRaw -eq 'acp') { [string][char]0xE713 } else { [string][char]0xE968 }
  $icon.FontFamily = [Windows.Media.FontFamily]::new('Segoe MDL2 Assets')
  $icon.FontSize = 14
  $icon.Foreground = New-Brush '#22D3EE'
  $icon.Effect = New-Object Windows.Media.Effects.DropShadowEffect -Property @{ Color = [Windows.Media.ColorConverter]::ConvertFromString('#06B6D4'); BlurRadius = 7; ShadowDepth = 0; Opacity = 0.45 }
  $icon.HorizontalAlignment = 'Center'; $icon.VerticalAlignment = 'Center'
  $iconBorder.Child = $icon
  [Windows.Controls.Grid]::SetColumn($iconBorder,0)

  $name = New-Object Windows.Controls.TextBlock
  $name.Text = $labelText
  $name.Foreground = New-Brush '#DDE6F0'
  $name.FontFamily = [Windows.Media.FontFamily]::new('Rajdhani, Segoe UI')
  $name.FontSize = 13
  $name.FontWeight = [Windows.FontWeights]::Bold
  $name.VerticalAlignment = 'Center'
  $name.TextTrimming = 'CharacterEllipsis'
  [Windows.Controls.Grid]::SetColumn($name,1)

  $health = Get-ServerHealthStatus $srv
  $isOnline = ($health -eq 'online')
  $dot = New-Object Windows.Shapes.Ellipse
  $dot.Width = 6; $dot.Height = 6
  $dot.Fill = if ($isOnline) { New-Brush '#10B981' } else { New-Brush '#EF4444' }
  $dot.Effect = New-Object Windows.Media.Effects.DropShadowEffect -Property @{ Color = [Windows.Media.ColorConverter]::ConvertFromString($(if($isOnline){'#10B981'}else{'#EF4444'})); BlurRadius = 6; ShadowDepth = 0; Opacity = 0.70 }
  $dot.HorizontalAlignment = 'Right'; $dot.VerticalAlignment = 'Center'
  [Windows.Controls.Grid]::SetColumn($dot,2)

  $top.Children.Add($iconBorder) | Out-Null
  $top.Children.Add($name) | Out-Null
  $top.Children.Add($dot) | Out-Null

  $meta = New-Object Windows.Controls.WrapPanel
  $meta.Margin = [Windows.Thickness]::new(0,0,0,0)
  $lastVersion = Get-LastServerVersion $srv
  if ([string]::IsNullOrWhiteSpace($lastVersion)) { $lastVersion = 'v?' }
  $meta.Children.Add((New-ServerTag $lastVersion 'version')) | Out-Null
  if ($isOnline) { $meta.Children.Add((New-ServerTag '● Online' 'online')) | Out-Null } else { $meta.Children.Add((New-ServerTag '● Offline' 'offline')) | Out-Null }
  $keyStatus = Get-KeyStatusText $srv
  if ($keyStatus -eq 'Key OK') { $meta.Children.Add((New-ServerTag '🔑 Key OK' 'key')) | Out-Null } else { $meta.Children.Add((New-ServerTag '⚠ Key fehlt' 'nokey')) | Out-Null }

  $hostTextBlock = New-Object Windows.Controls.TextBlock
  $hostTextBlock.Text = $hostLine
  $hostTextBlock.Foreground = New-Brush '#4A5E7A'
  $hostTextBlock.FontFamily = [Windows.Media.FontFamily]::new('JetBrains Mono, Cascadia Mono, Consolas')
  $hostTextBlock.FontSize = 9
  $hostTextBlock.Margin = [Windows.Thickness]::new(1,5,0,0)
  $hostTextBlock.TextTrimming = 'CharacterEllipsis'

  $inner.Children.Add($top) | Out-Null
  $inner.Children.Add($meta) | Out-Null
  $inner.Children.Add($hostTextBlock) | Out-Null
  $root.Children.Add($line) | Out-Null
  $root.Children.Add($inner) | Out-Null
  $btn.Content = $root
  $btn.Add_Click({
    $script:SelectedServer = $this.Tag
    Add-UiLog "Server gewählt: $($this.Tag.label)"
    Refresh-ServerButtons
  })
  return $btn
}
function Refresh-ServerButtons() {
  foreach ($child in $script:ServerList.Children) {
    $active = ($child.Tag -eq $script:SelectedServer)
    $line = Find-ChildByTag $child.Content 'ActiveLine'
    if ($active) {
      $child.Background = New-Brush '#E6111E36'
      $child.BorderBrush = New-Brush '#8C22D3EE'
      $child.Effect = New-Object Windows.Media.Effects.DropShadowEffect -Property @{ Color = [Windows.Media.ColorConverter]::ConvertFromString('#06B6D4'); BlurRadius = 14; ShadowDepth = 0; Opacity = 0.30 }
      if ($null -ne $line) { $line.Visibility = 'Visible' }
    } else {
      $child.Background = New-Brush '#0A1020'
      $child.BorderBrush = New-Brush '#0D22D3EE'
      $child.Effect = $null
      if ($null -ne $line) { $line.Visibility = 'Collapsed' }
    }
  }
  Update-SelectedServerSummary
}

function Refresh-ServerCardsAfterStateChange() {
  try {
    $selectedKeys = @()
    if ($script:SelectedServer) { $selectedKeys = @(Get-ServerIdentityKeys $script:SelectedServer) }
    $script:ServerList.Children.Clear()
    foreach ($srv in $script:Servers) {
      $btn = New-ServerCardButton $srv
      $script:ServerList.Children.Add($btn) | Out-Null
      if ($selectedKeys.Count -gt 0) {
        $srvKeys = @(Get-ServerIdentityKeys $srv)
        foreach ($k in $srvKeys) {
          if ($selectedKeys -contains $k) { $script:SelectedServer = $srv; break }
        }
      }
    }
    Refresh-ServerButtons
  } catch {
    try { Add-UiLog ('FEHLER: Serverkarten konnten nicht aktualisiert werden: ' + $_.Exception.Message) } catch {}
  }
}

function Get-DeployStateItems() {
  $map = @{}
  foreach ($path in @($script:DeployStateFile, $script:DeployStateFileConfig)) {
    if ([string]::IsNullOrWhiteSpace($path) -or -not (Test-Path -LiteralPath $path)) { continue }
    try {
      $raw = Get-Content -LiteralPath $path -Raw -Encoding UTF8
      if ([string]::IsNullOrWhiteSpace($raw)) { continue }
      $obj = $raw | ConvertFrom-Json
      foreach ($prop in $obj.PSObject.Properties) { $map[$prop.Name] = $prop.Value }
    } catch {}
  }
  return $map
}

function Save-DeployStateItems($map) {
  try {
    $obj = [ordered]@{}
    foreach ($key in $map.Keys) { $obj[$key] = $map[$key] }
    $json = ($obj | ConvertTo-Json -Depth 10)
    foreach ($path in @($script:DeployStateFile, $script:DeployStateFileConfig)) {
      if ([string]::IsNullOrWhiteSpace($path)) { continue }
      New-Item -ItemType Directory -Force -Path (Split-Path -Parent $path) | Out-Null
      $tmp = $path + '.tmp'
      [System.IO.File]::WriteAllText($tmp, $json, $script:Utf8NoBom)
      if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue }
      Move-Item -LiteralPath $tmp -Destination $path -Force
    }
  } catch { try { Add-UiLog ('FEHLER: Deploy Status konnte nicht gespeichert werden: ' + $_.Exception.Message) } catch {} }
}

function Get-ServerIdentityKeys($srv) {
  $keys = New-Object System.Collections.Generic.List[string]
  if ($null -eq $srv) { return @() }
  $id = if ($srv.PSObject.Properties.Name -contains 'id' -and $srv.id) { [string]$srv.id } else { '' }
  $label = if ($srv.PSObject.Properties.Name -contains 'label' -and $srv.label) { [string]$srv.label } else { $id }
  $kind = if ($srv.PSObject.Properties.Name -contains 'kind' -and $srv.kind) { ([string]$srv.kind).ToLowerInvariant() } else { '' }
  $hostName = if ($srv.PSObject.Properties.Name -contains 'host' -and $srv.host) { [string]$srv.host } else { '' }
  foreach ($value in @($id, $label, "$kind|$hostName", "$kind|$label", "$kind|$id")) {
    if (-not [string]::IsNullOrWhiteSpace($value)) { $keys.Add(($value.Trim().ToLowerInvariant())) | Out-Null }
  }
  return @($keys | Select-Object -Unique)
}

function Get-LastServerVersionFromState($srv) {
  try {
    $map = Get-DeployStateItems
    foreach ($key in (Get-ServerIdentityKeys $srv)) {
      if ($map.ContainsKey($key)) {
        $item = $map[$key]
        $version = Get-ObjectPropertyString $item 'version'
        if (-not [string]::IsNullOrWhiteSpace($version) -and $version -ne 'manual') { return $version }
      }
    }
  } catch {}
  return ''
}

function Set-LastServerVersion($srv, [string]$zipName) {
  try {
    if ($null -eq $srv) { return }
    $version = Version-FromFile $zipName
    if ([string]::IsNullOrWhiteSpace($version) -or $version -eq 'manual') { return }
    $label = if ($srv.PSObject.Properties.Name -contains 'label' -and $srv.label) { [string]$srv.label } else { [string]$srv.id }
    $kind = if ($srv.PSObject.Properties.Name -contains 'kind' -and $srv.kind) { ([string]$srv.kind).ToLowerInvariant() } else { '' }
    $hostName = if ($srv.PSObject.Properties.Name -contains 'host' -and $srv.host) { [string]$srv.host } else { '' }
    $entry = [pscustomobject]@{
      version = $version
      zip = $zipName
      server = $label
      kind = $kind
      host = $hostName
      timestamp = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
    }
    $map = Get-DeployStateItems
    foreach ($key in (Get-ServerIdentityKeys $srv)) { $map[$key] = $entry }
    Save-DeployStateItems $map
  } catch { try { Add-UiLog ('FEHLER: letzte Deploy Version konnte nicht gespeichert werden: ' + $_.Exception.Message) } catch {} }
}



function Set-LastServerVersionDirect($srv, [string]$version, [string]$zipName, [string]$actionText) {
  try {
    if ($null -eq $srv) { return }
    if ([string]::IsNullOrWhiteSpace($version) -or $version -eq 'manual') { return }
    $label = if ($srv.PSObject.Properties.Name -contains 'label' -and $srv.label) { [string]$srv.label } else { [string]$srv.id }
    $kind = if ($srv.PSObject.Properties.Name -contains 'kind' -and $srv.kind) { ([string]$srv.kind).ToLowerInvariant() } else { '' }
    $hostName = if ($srv.PSObject.Properties.Name -contains 'host' -and $srv.host) { [string]$srv.host } else { '' }
    if ([string]::IsNullOrWhiteSpace($zipName)) { $zipName = "$kind-$version" }
    $entry = [pscustomobject]@{
      version = $version
      zip = $zipName
      server = $label
      kind = $kind
      host = $hostName
      timestamp = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
      action = $actionText
    }
    $map = Get-DeployStateItems
    foreach ($key in (Get-ServerIdentityKeys $srv)) { $map[$key] = $entry }
    Save-DeployStateItems $map
  } catch { try { Add-UiLog ('FEHLER: Server Version konnte nicht gespeichert werden: ' + $_.Exception.Message) } catch {} }
}

function Set-LastServerVersionFromRepair($srv, [string]$zipName) {
  try {
    if ($null -eq $srv) { return $false }
    $newVersion = Version-FromFile $zipName
    if ([string]::IsNullOrWhiteSpace($newVersion) -or $newVersion -eq 'manual') { return $false }
    $currentVersion = Get-LastServerVersionFromState $srv
    if (-not [string]::IsNullOrWhiteSpace($currentVersion) -and $currentVersion -ne 'manual') {
      $cmp = Compare-CrimsonVersion $newVersion $currentVersion
      if ($cmp -lt 0) { return $false }
    }
    Set-LastServerVersion $srv $zipName
    return $true
  } catch { return $false }
}

function Get-PrimaryServerIdentityKey($srv) {
  try {
    $keys = @(Get-ServerIdentityKeys $srv)
    if ($keys.Count -gt 0) { return [string]$keys[0] }
  } catch {}
  return ''
}

function Get-LastServerVersion($srv) {
  $stateVersion = Get-LastServerVersionFromState $srv
  if (-not [string]::IsNullOrWhiteSpace($stateVersion)) { return $stateVersion }
  try {
    if ($null -eq $srv) { return '' }
    $label = if ($srv.PSObject.Properties.Name -contains 'label' -and $srv.label) { [string]$srv.label } else { [string]$srv.id }
    $id = if ($srv.PSObject.Properties.Name -contains 'id' -and $srv.id) { [string]$srv.id } else { '' }
    $hostName = if ($srv.PSObject.Properties.Name -contains 'host' -and $srv.host) { [string]$srv.host } else { '' }
    $kind = if ($srv.PSObject.Properties.Name -contains 'kind' -and $srv.kind) { ([string]$srv.kind).ToLowerInvariant() } else { '' }
    $items = @(Get-HistoryItems)
    foreach ($item in $items) {
      $status = Get-ObjectPropertyString $item 'status'
      $action = Get-ObjectPropertyString $item 'action'
      $server = Get-ObjectPropertyString $item 'server'
      $entryKind = (Get-ObjectPropertyString $item 'kind').ToLowerInvariant()
      $entryHost = Get-ObjectPropertyString $item 'host'
      if ($status -notmatch '(?i)^Success$') { continue }
      if ($action -notmatch '(?i)^Deploy$') { continue }
      $serverMatches = ($server -eq $label) -or (-not [string]::IsNullOrWhiteSpace($id) -and $server -eq $id) -or (-not [string]::IsNullOrWhiteSpace($hostName) -and $entryHost -eq $hostName)
      $kindMatches = ([string]::IsNullOrWhiteSpace($entryKind) -or [string]::IsNullOrWhiteSpace($kind) -or $entryKind -eq $kind)
      if (-not ($serverMatches -or ($kindMatches -and -not [string]::IsNullOrWhiteSpace($entryKind)))) { continue }
      $zipName = Get-ObjectPropertyString $item 'zip'
      $version = Version-FromFile $zipName
      if (-not [string]::IsNullOrWhiteSpace($version) -and $version -ne 'manual') {
        try { Set-LastServerVersion $srv $zipName } catch {}
        return $version
      }
    }
  } catch {}
  return ''
}

function Load-Servers() {
  if (-not (Test-Path -LiteralPath $script:ConfigPath)) {
    Add-UiLog "FEHLER: config/servers.json fehlt: $script:ConfigPath"
    Set-Status 'Config fehlt' 'error'
    return
  }
  $raw = Get-Content -LiteralPath $script:ConfigPath -Raw -Encoding UTF8
  $cfg = $raw | ConvertFrom-Json
  $script:Servers = @($cfg.servers)
  $script:ServerList.Children.Clear()
  foreach ($srv in $script:Servers) {
    $btn = New-ServerCardButton $srv
    $script:ServerList.Children.Add($btn) | Out-Null
  }
  if ($script:Servers.Count -gt 0) { $script:SelectedServer = $script:Servers[0] }
  Refresh-ServerButtons
  Add-UiLog "$($script:Servers.Count) Server geladen."
}


function Set-StageBadgeVisual([Windows.Controls.Border]$badge, [bool]$active, [bool]$done, [bool]$errorState = $false) {
  if ($null -eq $badge) { return }
  $fg = '#4A5E7A'
  if ($errorState) {
    $badge.Background = New-Brush '#17EF4444'
    $badge.BorderBrush = New-Brush '#47EF4444'
    $badge.Effect = $null
    $fg = '#F87171'
  } elseif ($active) {
    $badge.Background = New-Brush '#1A06B6D4'
    $badge.BorderBrush = New-Brush '#8C22D3EE'
    $badge.Effect = New-Object Windows.Media.Effects.DropShadowEffect -Property @{ Color = [Windows.Media.ColorConverter]::ConvertFromString('#06B6D4'); BlurRadius = 6; ShadowDepth = 0; Opacity = 0.30 }
    $fg = '#22D3EE'
  } elseif ($done) {
    $badge.Background = New-Brush '#1710B981'
    $badge.BorderBrush = New-Brush '#4710B981'
    $badge.Effect = $null
    $fg = '#34D399'
  } else {
    $badge.Background = New-Brush '#111E36'
    $badge.BorderBrush = New-Brush '#0D22D3EE'
    $badge.Effect = $null
    $fg = '#4A5E7A'
  }
  try {
    if ($badge.Child -is [Windows.Controls.StackPanel]) {
      foreach ($c in $badge.Child.Children) {
        if ($c -is [Windows.Controls.TextBlock]) { $c.Foreground = New-Brush $fg; $c.FontWeight = [Windows.FontWeights]::SemiBold }
        if ($c -is [Windows.Shapes.Ellipse]) { $c.Fill = New-Brush $fg }
      }
    } elseif ($badge.Child -is [Windows.Controls.TextBlock]) {
      $badge.Child.Foreground = New-Brush $fg
      $badge.Child.FontWeight = [Windows.FontWeights]::SemiBold
    }
  } catch {}
}

function Update-StageBadges([double]$value) {
  if ($null -eq $script:StageBadges) { return }
  $thresholds = @($script:StageBadges | ForEach-Object { [double]$_.Threshold })
  $currentIndex = -1
  for ($i = 0; $i -lt $thresholds.Count; $i++) {
    if ($value -ge $thresholds[$i]) { $currentIndex = $i }
  }
  for ($i = 0; $i -lt $script:StageBadges.Count; $i++) {
    $item = $script:StageBadges[$i]
    $done = ($value -ge [double]$item.Threshold)
    $active = ($i -eq $currentIndex -and $value -lt 100)
    $err = ($script:StageHasError -and $i -eq $currentIndex)
    Set-StageBadgeVisual $item.Border $active $done $err
  }
}

function Set-ProgressStage([string]$text, [double]$value) {
  if ($value -lt 0) { $value = 0 }
  if ($value -gt 100) { $value = 100 }
  if ($text -match '(?i)Fehler|failed|fehlgeschlagen|Timeout') { $script:StageHasError = $true } elseif ($value -lt 100 -or $text -match '(?i)Bereit|gestartet|validiert') { $script:StageHasError = $false
$script:AppIconSource = $null }
  if ($script:StepText) { $script:StepText.Text = $text }
  if ($script:StepProgress) { $script:StepProgress.Value = $value }
  if ($script:StatusPercentText) { $script:StatusPercentText.Text = ([int]$value).ToString() + '%' }
  Update-StageBadges $value
}

function Update-ProgressFromLine([string]$line) {
  if ([string]::IsNullOrWhiteSpace($line)) { return }
  switch -Regex ($line) {
    '(?i)ZIP gewählt|ZIP Validierung erfolgreich' { Set-ProgressStage 'ZIP validiert' 10; break }
    '(?i)TCP Vorprüfung|TCP Test startet|Preflight' { Set-ProgressStage 'Server wird geprüft' 18; break }
    '(?i)SCP Upload|Upload.*startet|scp\.exe' { Set-ProgressStage 'Upload läuft' 30; break }
    '(?i)Upload abgeschlossen' { Set-ProgressStage 'Upload abgeschlossen' 42; break }
    '(?i)Deploy startet|Remote Script|Hub Deploy startet|ACP Deploy startet' { Set-ProgressStage 'Remote Deploy läuft' 52; break }
    '(?i)Backup erstellen|Backup:' { Set-ProgressStage 'Backup wird erstellt' 62; break }
    '(?i)rsync|Dateien ersetzt|Entpacke' { Set-ProgressStage 'Dateien werden ersetzt' 68; break }
    '(?i)npm install|npm run|Prisma|Build' { Set-ProgressStage 'Build und Abhängigkeiten' 78; break }
    '(?i)Service Neustart|PM2 Neustart|Restart' { Set-ProgressStage 'Service Neustart' 86; break }
    '(?i)Health Check|online|is-active' { Set-ProgressStage 'Health Check' 92; break }
    '(?i)Deploy Status: success|Deploy abgeschlossen|Rollback Status: success|Preflight Status: success' { Set-ProgressStage 'Abgeschlossen' 100; break }
    '(?i)Deploy Status: failed|FEHLER|fehlgeschlagen|Timeout nach' { if ($script:IsRunning) { Set-ProgressStage 'Fehler erkannt' 100 }; break }
  }
}

function Set-ControlsRunning([bool]$running) {
  $script:IsRunning = $running
  if ($script:DeployButton) { $script:DeployButton.IsEnabled = -not $running }
  if ($script:PickZipButton) { $script:PickZipButton.IsEnabled = -not $running }
  if ($script:PreflightButton) { $script:PreflightButton.IsEnabled = -not $running }
  if ($script:RollbackButton) { $script:RollbackButton.IsEnabled = -not $running }
  if ($script:ServerManagerButton) { $script:ServerManagerButton.IsEnabled = -not $running }
  if ($script:InstallUpdateButton) { $script:InstallUpdateButton.IsEnabled = ((-not $running) -and (-not [string]::IsNullOrWhiteSpace($script:SelectedUpdatePackage))) }
  if ($script:CancelButton) { $script:CancelButton.IsEnabled = $running }
}

function Get-HistoryItems() {
  if (-not (Test-Path -LiteralPath $script:HistoryFile)) { return @() }
  try {
    $raw = Get-Content -LiteralPath $script:HistoryFile -Raw -Encoding UTF8
    if ([string]::IsNullOrWhiteSpace($raw)) { return @() }
    return @($raw | ConvertFrom-Json)
  } catch { return @() }
}

function Save-HistoryItems($items) {
  try {
    $keepDays = Get-AppSettingInt 'keepHistoryDays' 180 7
    $cutoff = (Get-Date).AddDays(-1 * $keepDays)
    $filtered = @()
    foreach ($item in @($items)) {
      $tsText = Get-ObjectPropertyString $item 'timestamp'
      if ([string]::IsNullOrWhiteSpace($tsText)) { $filtered += $item; continue }
      $dt = [datetime]::MinValue
      if ([datetime]::TryParse($tsText, [ref]$dt)) {
        if ($dt -ge $cutoff) { $filtered += $item }
      } else { $filtered += $item }
    }
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $script:HistoryFile) | Out-Null
    $json = @($filtered) | ConvertTo-Json -Depth 8
    [System.IO.File]::WriteAllText($script:HistoryFile, $json, $script:Utf8NoBom)
  } catch {
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $script:HistoryFile) | Out-Null
    $json = @($items) | ConvertTo-Json -Depth 8
    [System.IO.File]::WriteAllText($script:HistoryFile, $json, $script:Utf8NoBom)
  }
}

function New-HistoryEntry([string]$action, [string]$status, [string]$details) {
  $duration = ''
  if ($script:CurrentStart) { $duration = ([int]((Get-Date) - $script:CurrentStart).TotalSeconds).ToString() + 's' }
  $hostName = ''
  if ($script:SelectedServer -and ($script:SelectedServer.PSObject.Properties.Name -contains 'host') -and $script:SelectedServer.host) { $hostName = [string]$script:SelectedServer.host }
  return [pscustomobject]@{
    timestamp = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
    appVersion = $script:AppVersion
    action = $action
    server = $script:CurrentServerLabel
    kind = $script:CurrentKind
    host = $hostName
    zip = $script:CurrentZipName
    zipVersion = (Version-FromFile $script:CurrentZipName)
    status = $status
    duration = $duration
    log = $script:JobLogFile
    details = $details
  }
}

function Add-HistoryRecord([string]$action, [string]$status, [string]$details) {
  try {
    $entry = New-HistoryEntry $action $status $details
    $items = @(Get-HistoryItems)
    $isDuplicate = $false
    foreach ($item in $items) {
      $sameAction = ((Get-ObjectPropertyString $item 'action') -eq ([string]$entry.action))
      $sameStatus = ((Get-ObjectPropertyString $item 'status') -eq ([string]$entry.status))
      $sameZip = ((Get-ObjectPropertyString $item 'zip') -eq ([string]$entry.zip))
      $sameServer = ((Get-ObjectPropertyString $item 'server') -eq ([string]$entry.server))
      $sameLog = ((Get-ObjectPropertyString $item 'log') -eq ([string]$entry.log))
      if ($sameAction -and $sameStatus -and $sameZip -and $sameServer -and $sameLog) { $isDuplicate = $true; break }
    }
    if (-not $isDuplicate) {
      $items = @($entry) + $items
      if ($items.Count -gt 120) { $items = $items[0..119] }
      Save-HistoryItems $items
    }
  } catch { try { Add-UiLog ('FEHLER: Verlauf konnte nicht geschrieben werden: ' + $_.Exception.Message) } catch {} }
}

function Register-DeploySuccess([string]$source) {
  if ($script:DeploySuccessRecorded) { return }
  try {
    if ($script:CurrentAction -ne 'Deploy') { return }
    if ([string]::IsNullOrWhiteSpace($script:CurrentZipName)) { return }
    Set-LastServerVersion $script:SelectedServer $script:CurrentZipName
    Add-HistoryRecord 'Deploy' 'Success' ("Erfolg erkannt über $source")
    $script:DeploySuccessRecorded = $true
    Add-UiLog ("Deploy Version gespeichert: " + (Version-FromFile $script:CurrentZipName)); Show-CrimsonToast 'Deploy erfolgreich' ((Get-ServerLabel $script:SelectedServer) + ' · ' + (Version-FromFile $script:CurrentZipName)) 'success'
    try { Invoke-AutoConfigBackupIfEnabled } catch {}
    try { Refresh-ServerCardsAfterStateChange } catch {}
  } catch { try { Add-UiLog ('FEHLER: Deploy Erfolg konnte nicht gespeichert werden: ' + $_.Exception.Message) } catch {} }
}


function Add-RollbackHistoryRecord([string]$status, [string]$details) {
  try {
    $duration = ''
    if ($script:CurrentStart) { $duration = ([int]((Get-Date) - $script:CurrentStart).TotalSeconds).ToString() + 's' }
    $hostName = ''
    if ($script:SelectedServer -and ($script:SelectedServer.PSObject.Properties.Name -contains 'host') -and $script:SelectedServer.host) { $hostName = [string]$script:SelectedServer.host }
    $entry = [pscustomobject]@{
      timestamp = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
      appVersion = $script:AppVersion
      action = 'Rollback'
      server = $script:CurrentServerLabel
      kind = $script:CurrentKind
      host = $hostName
      zip = $script:CurrentZipName
      zipVersion = $script:CurrentRollbackVersion
      status = $status
      duration = $duration
      log = $script:JobLogFile
      details = $details
    }
    $items = @(Get-HistoryItems)
    $items = @($entry) + $items
    if ($items.Count -gt 120) { $items = $items[0..119] }
    Save-HistoryItems $items
  } catch { try { Add-UiLog ('FEHLER: Rollback Verlauf konnte nicht geschrieben werden: ' + $_.Exception.Message) } catch {} }
}

function Register-RollbackSuccess([string]$source) {
  if ($script:RollbackSuccessRecorded) { return }
  try {
    if ($script:CurrentAction -ne 'Rollback') { return }
    if ([string]::IsNullOrWhiteSpace($script:CurrentRollbackVersion)) { return }
    Set-LastServerVersionDirect $script:SelectedServer $script:CurrentRollbackVersion $script:CurrentZipName 'Rollback'
    Add-RollbackHistoryRecord 'Success' ("Rollback Erfolg erkannt über $source")
    $script:RollbackSuccessRecorded = $true
    Add-UiLog ("Rollback Version gespeichert: " + $script:CurrentRollbackVersion); Show-CrimsonToast 'Rollback erfolgreich' ((Get-ServerLabel $script:SelectedServer) + ' · ' + $script:CurrentRollbackVersion) 'success'
    try { Invoke-AutoConfigBackupIfEnabled } catch {}
    try { Refresh-ServerCardsAfterStateChange } catch {}
  } catch { try { Add-UiLog ('FEHLER: Rollback Erfolg konnte nicht gespeichert werden: ' + $_.Exception.Message) } catch {} }
}


function Find-ServerByKindHost([string]$kind, [string]$hostName) {
  foreach ($srv in $script:Servers) {
    $srvKind = if ($srv.PSObject.Properties.Name -contains 'kind' -and $srv.kind) { ([string]$srv.kind).ToLowerInvariant() } else { '' }
    $srvHost = if ($srv.PSObject.Properties.Name -contains 'host' -and $srv.host) { [string]$srv.host } else { '' }
    if (-not [string]::IsNullOrWhiteSpace($hostName) -and $srvHost -eq $hostName) { return $srv }
    if (-not [string]::IsNullOrWhiteSpace($kind) -and $srvKind -eq $kind.ToLowerInvariant()) { return $srv }
  }
  return $null
}

function Add-HistoryRecordFromParts([string]$serverLabel, [string]$kind, [string]$hostName, [string]$zipName, [string]$logPath, [string]$timestamp) {
  try {
    if ([string]::IsNullOrWhiteSpace($zipName)) { return }
    $zipVersion = Version-FromFile $zipName
    if ([string]::IsNullOrWhiteSpace($zipVersion) -or $zipVersion -eq 'manual') { return }
    $items = @(Get-HistoryItems)
    foreach ($item in $items) {
      if ((Get-ObjectPropertyString $item 'status') -eq 'Success' -and (Get-ObjectPropertyString $item 'action') -eq 'Deploy' -and (Get-ObjectPropertyString $item 'zip') -eq $zipName -and ((Get-ObjectPropertyString $item 'host') -eq $hostName -or (Get-ObjectPropertyString $item 'kind').ToLowerInvariant() -eq $kind.ToLowerInvariant())) { return }
    }
    $entry = [pscustomobject]@{
      timestamp = $(if ([string]::IsNullOrWhiteSpace($timestamp)) { (Get-Date).ToString('yyyy-MM-dd HH:mm:ss') } else { $timestamp })
      appVersion = $script:AppVersion
      action = 'Deploy'
      server = $serverLabel
      kind = $kind
      host = $hostName
      zip = $zipName
      zipVersion = $zipVersion
      status = 'Success'
      duration = ''
      log = $logPath
      details = 'Aus bestehendem Job Log rekonstruiert'
    }
    $items = @($entry) + $items
    if ($items.Count -gt 120) { $items = $items[0..119] }
    Save-HistoryItems $items
  } catch {}
}

function Repair-DeployHistoryAndState() {
  try {
    if (-not (Test-Path -LiteralPath $script:LogDir)) { return }
    $jobLogs = @(Get-ChildItem -LiteralPath $script:LogDir -Filter 'crimson-deploy-job-*.log' -File -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 80)
    $added = 0
    $stateWrittenKeys = New-Object System.Collections.Generic.HashSet[string]
    foreach ($logFile in $jobLogs) {
      $raw = ''
      try { $raw = Get-Content -LiteralPath $logFile.FullName -Raw -Encoding UTF8 -ErrorAction Stop } catch { continue }
      if ([string]::IsNullOrWhiteSpace($raw)) { continue }
      $raw = [string]$raw
      if ($raw -notmatch '(?im)^\s*Deploy Status:\s*success\s*$') { continue }
      $zipName = ''
      $kind = ''
      $hostName = ''
      $serverLabel = ''
      $mZip = [regex]::Match($raw, '(?im)^\s*Lokale ZIP:\s*(.+)$')
      if ($mZip.Success) { $zipName = Safe-FileName $mZip.Groups[1].Value.Trim() }
      if ([string]::IsNullOrWhiteSpace($zipName)) {
        $mZip = [regex]::Match($raw, '(?im)^\s*Remote Ziel:\s*[^@\s]+@[^:]+:/tmp/([^\r\n]+)$')
        if ($mZip.Success) { $zipName = Safe-FileName $mZip.Groups[1].Value.Trim() }
      }
      $mKind = [regex]::Match($raw, '(?im)^\s*Deploy Typ:\s*(\w+)\s*$')
      if ($mKind.Success) { $kind = $mKind.Groups[1].Value.Trim().ToLowerInvariant() }
      $mHost = [regex]::Match($raw, '(?im)^\s*Remote Ziel:\s*[^@\s]+@([^:]+):')
      if ($mHost.Success) { $hostName = $mHost.Groups[1].Value.Trim() }
      $srv = Find-ServerByKindHost $kind $hostName
      if ($srv) {
        $serverLabel = if ($srv.PSObject.Properties.Name -contains 'label' -and $srv.label) { [string]$srv.label } else { [string]$srv.id }
        $primaryKey = Get-PrimaryServerIdentityKey $srv
        if (-not [string]::IsNullOrWhiteSpace($primaryKey) -and -not $stateWrittenKeys.Contains($primaryKey)) {
          if (Set-LastServerVersionFromRepair $srv $zipName) { [void]$stateWrittenKeys.Add($primaryKey) }
        }
      }
      if ([string]::IsNullOrWhiteSpace($serverLabel)) { $serverLabel = $(if (-not [string]::IsNullOrWhiteSpace($kind)) { $kind.ToUpperInvariant() } else { 'Server' }) }
      Add-HistoryRecordFromParts $serverLabel $kind $hostName $zipName $logFile.FullName $logFile.LastWriteTime.ToString('yyyy-MM-dd HH:mm:ss')
      $added++
    }
    if ($added -gt 0) { Add-UiLog "Deploy Verlauf geprüft: $added erfolgreiche Deploy Logs erkannt." }
  } catch { try { Add-UiLog ('WARNUNG: Deploy Verlauf konnte nicht rekonstruiert werden: ' + $_.Exception.Message) } catch {} }
}

function New-HistoryCard($item) {
  $action = Get-ObjectPropertyString $item 'action'
  if ([string]::IsNullOrWhiteSpace($action)) { $action = 'Deploy' }
  $status = Get-ObjectPropertyString $item 'status'
  $server = Get-ObjectPropertyString $item 'server'
  $kind = Get-ObjectPropertyString $item 'kind'
  $zip = Get-ObjectPropertyString $item 'zip'
  $version = Get-ObjectPropertyString $item 'zipVersion'
  if ([string]::IsNullOrWhiteSpace($version)) { $version = Version-FromFile $zip }
  $timestamp = Get-ObjectPropertyString $item 'timestamp'
  $duration = Get-ObjectPropertyString $item 'duration'
  $details = Get-ObjectPropertyString $item 'details'
  $logPath = Get-ObjectPropertyString $item 'log'
  $ok = ($status -match '(?i)success|erfolg')
  $warn = ($status -match '(?i)abgebrochen|warn')
  $color = '#8FA3BE'
  $badgeBg = '#0A1020'
  $border = '#183148'
  if ($ok) { $color = '#34D399'; $badgeBg = '#092017'; $border = '#164638' }
  elseif ($warn) { $color = '#FBBF24'; $badgeBg = '#271D08'; $border = '#4B3A13' }
  elseif ($status -match '(?i)fail|fehler|error') { $color = '#F87171'; $badgeBg = '#2A0D13'; $border = '#45202A' }

  $card = [Windows.Controls.Border]::new()
  $card.CornerRadius = [Windows.CornerRadius]::new(12)
  $card.Margin = [Windows.Thickness]::new(0,0,0,10)
  $card.Padding = [Windows.Thickness]::new(14)
  $card.Background = New-Brush '#0A1020'
  $card.BorderBrush = New-Brush $border
  $card.BorderThickness = [Windows.Thickness]::new(1)

  $stack = [Windows.Controls.StackPanel]::new()
  $top = [Windows.Controls.Grid]::new()
  $c1 = [Windows.Controls.ColumnDefinition]::new(); $c1.Width = [Windows.GridLength]::new(1,[Windows.GridUnitType]::Star); $top.ColumnDefinitions.Add($c1) | Out-Null
  $c2 = [Windows.Controls.ColumnDefinition]::new(); $c2.Width = [Windows.GridLength]::Auto; $top.ColumnDefinitions.Add($c2) | Out-Null

  $title = [Windows.Controls.TextBlock]::new()
  $title.Text = "$action · $server"
  $title.Foreground = New-Brush '#DDE6F0'
  $title.FontFamily = [Windows.Media.FontFamily]::new('Rajdhani, Segoe UI Semibold, Segoe UI')
  $title.FontSize = 18
  $title.FontWeight = [Windows.FontWeights]::Bold
  $title.TextTrimming = 'CharacterEllipsis'

  $badge = [Windows.Controls.Border]::new()
  $badge.CornerRadius = [Windows.CornerRadius]::new(5)
  $badge.Background = New-Brush $badgeBg
  $badge.BorderBrush = New-Brush $border
  $badge.BorderThickness = [Windows.Thickness]::new(1)
  $badge.Padding = [Windows.Thickness]::new(8,3,8,3)
  $bt = [Windows.Controls.TextBlock]::new()
  $bt.Text = $(if ([string]::IsNullOrWhiteSpace($status)) { 'UNBEKANNT' } else { $status.ToUpperInvariant() })
  $bt.Foreground = New-Brush $color
  $bt.FontFamily = [Windows.Media.FontFamily]::new('JetBrains Mono, Cascadia Mono, Consolas')
  $bt.FontSize = 9
  $bt.FontWeight = [Windows.FontWeights]::Bold
  $badge.Child = $bt
  [Windows.Controls.Grid]::SetColumn($badge,1)

  $top.Children.Add($title) | Out-Null
  $top.Children.Add($badge) | Out-Null

  $meta = [Windows.Controls.TextBlock]::new()
  $meta.Text = "Version $version · $kind · $timestamp"
  $meta.Foreground = New-Brush '#22D3EE'
  $meta.FontFamily = [Windows.Media.FontFamily]::new('JetBrains Mono, Cascadia Mono, Consolas')
  $meta.FontSize = 10.5
  $meta.Margin = [Windows.Thickness]::new(0,6,0,0)
  $meta.TextTrimming = 'CharacterEllipsis'

  $zipText = [Windows.Controls.TextBlock]::new()
  $zipText.Text = $(if ([string]::IsNullOrWhiteSpace($zip)) { 'Paket: unbekannt' } else { "Paket: $zip" })
  $zipText.Foreground = New-Brush '#8FA3BE'
  $zipText.FontSize = 11
  $zipText.Margin = [Windows.Thickness]::new(0,6,0,0)
  $zipText.TextWrapping = 'Wrap'

  $detailsText = [Windows.Controls.TextBlock]::new()
  $line = ''
  if (-not [string]::IsNullOrWhiteSpace($duration)) { $line = "Dauer: $duration" }
  if (-not [string]::IsNullOrWhiteSpace($details)) { if ($line) { $line += ' · ' }; $line += $details }
  if (-not [string]::IsNullOrWhiteSpace($logPath)) { if ($line) { $line += "`n" }; $line += "Log: $logPath" }
  $detailsText.Text = $line
  $detailsText.Foreground = New-Brush '#4A5E7A'
  $detailsText.FontSize = 10.5
  $detailsText.Margin = [Windows.Thickness]::new(0,6,0,0)
  $detailsText.TextWrapping = 'Wrap'

  $stack.Children.Add($top) | Out-Null
  $stack.Children.Add($meta) | Out-Null
  $stack.Children.Add($zipText) | Out-Null
  if (-not [string]::IsNullOrWhiteSpace($line)) { $stack.Children.Add($detailsText) | Out-Null }
  $card.Child = $stack
  return $card
}

function Show-HistoryWindow() {
  try {
    $items = @(Get-HistoryItems)
    $win = [Windows.Window]::new()
    $win.Title = 'Deploy Verlauf'
    $win.Width = 980
    $win.Height = 640
    $win.MinWidth = 760
    $win.MinHeight = 540
    $win.WindowStartupLocation = 'CenterOwner'
    $win.Owner = $script:Window
    $win.Background = New-Brush '#04070F'
    Apply-CrimsonSubWindowStyle $win

    $outer = [Windows.Controls.Grid]::new()
    $outer.Margin = [Windows.Thickness]::new(22)
    $r1 = [Windows.Controls.RowDefinition]::new(); $r1.Height = [Windows.GridLength]::Auto; $outer.RowDefinitions.Add($r1) | Out-Null
    $r2 = [Windows.Controls.RowDefinition]::new(); $r2.Height = [Windows.GridLength]::new(1,[Windows.GridUnitType]::Star); $outer.RowDefinitions.Add($r2) | Out-Null
    $r3 = [Windows.Controls.RowDefinition]::new(); $r3.Height = [Windows.GridLength]::Auto; $outer.RowDefinitions.Add($r3) | Out-Null

    $header = [Windows.Controls.StackPanel]::new()
    $header.Margin = [Windows.Thickness]::new(0,0,0,16)
    $h = [Windows.Controls.TextBlock]::new(); $h.Text = 'Deploy Verlauf'; $h.Foreground = New-Brush '#DDE6F0'; $h.FontFamily = [Windows.Media.FontFamily]::new('Rajdhani, Segoe UI Semibold, Segoe UI'); $h.FontSize = 24; $h.FontWeight = [Windows.FontWeights]::Bold
    $p = [Windows.Controls.TextBlock]::new(); $p.Text = 'Letzte Deployments, Rollbacks und abgebrochene Aktionen. Neue Einträge stehen oben.'; $p.Foreground = New-Brush '#8FA3BE'; $p.FontSize = 12; $p.TextWrapping = 'Wrap'
    $header.Children.Add($h) | Out-Null; $header.Children.Add($p) | Out-Null
    $outer.Children.Add($header) | Out-Null

    $scroll = [Windows.Controls.ScrollViewer]::new(); $scroll.VerticalScrollBarVisibility = 'Auto'; $scroll.HorizontalScrollBarVisibility = 'Disabled'; $scroll.Background = [Windows.Media.Brushes]::Transparent; [Windows.Controls.Grid]::SetRow($scroll,1)
    $list = [Windows.Controls.StackPanel]::new(); $scroll.Content = $list
    if ($items.Count -eq 0) {
      $empty = [Windows.Controls.Border]::new(); $empty.CornerRadius = [Windows.CornerRadius]::new(14); $empty.Padding = [Windows.Thickness]::new(22); $empty.Background = New-Brush '#0A1020'; $empty.BorderBrush = New-Brush '#183148'; $empty.BorderThickness = [Windows.Thickness]::new(1)
      $et = [Windows.Controls.TextBlock]::new(); $et.Text = 'Noch keine Deployments vorhanden.'; $et.Foreground = New-Brush '#8FA3BE'; $et.FontSize = 13; $et.HorizontalAlignment = 'Center'; $et.TextAlignment = 'Center'
      $empty.Child = $et; $list.Children.Add($empty) | Out-Null
    } else {
      foreach ($item in @($items | Select-Object -First 150)) { $list.Children.Add((New-HistoryCard $item)) | Out-Null }
    }
    $outer.Children.Add($scroll) | Out-Null

    $panel = [Windows.Controls.StackPanel]::new(); $panel.Orientation = 'Horizontal'; $panel.HorizontalAlignment = 'Right'; $panel.Margin = [Windows.Thickness]::new(0,16,0,0); [Windows.Controls.Grid]::SetRow($panel,2)
    $openBtn = [Windows.Controls.Button]::new(); $openBtn.Content='Verlaufsdatei öffnen'; $openBtn.Width=160; $openBtn.Height=38; $openBtn.Margin=[Windows.Thickness]::new(0,0,10,0); $openBtn.Background=New-Brush '#0D1528'; $openBtn.Foreground=New-Brush '#22D3EE'; $openBtn.BorderBrush=New-Brush '#224F63'; $openBtn.FontWeight=[Windows.FontWeights]::SemiBold
    $openBtn.Add_Click({ if (Test-Path -LiteralPath $script:HistoryFile) { Start-Process notepad.exe -ArgumentList ('"' + $script:HistoryFile + '"') } })
    $closeBtn = [Windows.Controls.Button]::new(); $closeBtn.Content='Schließen'; $closeBtn.Width=110; $closeBtn.Height=38; $closeBtn.Background=New-Brush '#0D1528'; $closeBtn.Foreground=New-Brush '#8FA3BE'; $closeBtn.BorderBrush=New-Brush '#183148'; $closeBtn.FontWeight=[Windows.FontWeights]::SemiBold
    $closeBtn.Add_Click({ $win.Close() })
    $panel.Children.Add($openBtn)|Out-Null; $panel.Children.Add($closeBtn)|Out-Null
    $outer.Children.Add($panel)|Out-Null
    $win.Content = $outer
    [void]$win.ShowDialog()
  } catch { Add-UiLog ('FEHLER: Deploy Verlauf konnte nicht geöffnet werden: ' + $_.Exception.Message) }
}

function Validate-ZipPackage([string]$path, [string]$expectedKind) {
  if ([string]::IsNullOrWhiteSpace($path)) { throw 'Keine ZIP gewählt.' }
  if (-not (Test-Path -LiteralPath $path)) { throw "ZIP nicht gefunden: $path" }
  if ([IO.Path]::GetExtension($path).ToLowerInvariant() -ne '.zip') { throw 'Datei ist keine ZIP.' }
  $fileName = Safe-FileName $path
  $zipKind = Detect-Kind $fileName
  if ($null -eq $zipKind) { throw 'ZIP Name nicht erkannt. Erlaubt: crimson-hub-1.0.0.zip, crimson-acp-1.0.0.zip oder Legacy crimson-hub-vXX.zip.' }
  if ($zipKind -ne $expectedKind) { throw "ZIP Typ $zipKind passt nicht zum Server Typ $expectedKind." }
  $sizeMb = [math]::Round(((Get-Item -LiteralPath $path).Length / 1MB), 2)
  if ($sizeMb -gt 500) { Add-UiLog "WARNUNG: ZIP ist groß: ${sizeMb} MB" }
  $zip = $null
  try {
    $zip = [System.IO.Compression.ZipFile]::OpenRead($path)
    if ($zip.Entries.Count -eq 0) { throw 'ZIP ist leer.' }
    $names = @($zip.Entries | ForEach-Object { ($_.FullName -replace '\\','/') })
    foreach ($n in $names) {
      if ($n.StartsWith('/') -or $n -match '^[A-Za-z]:/' -or $n -match '(^|/)\.\.(/|$)') { throw "Unsicherer Pfad in ZIP: $n" }
    }
    if ($zipKind -eq 'hub') {
      if (-not ($names -contains 'package.json')) { throw 'Hub ZIP ungültig: package.json fehlt im ZIP Root.' }
      if (-not ($names -contains 'prisma/schema.prisma')) { throw 'Hub ZIP ungültig: prisma/schema.prisma fehlt.' }
      if (-not ($names | Where-Object { $_ -like 'src/*' } | Select-Object -First 1)) { throw 'Hub ZIP ungültig: src Ordner fehlt.' }
    } elseif ($zipKind -eq 'acp') {
      if (-not ($names -contains 'server.js')) { throw 'ACP ZIP ungültig: server.js fehlt im ZIP Root.' }
      if (-not ($names -contains 'package.json')) { throw 'ACP ZIP ungültig: package.json fehlt im ZIP Root.' }
      if (-not ($names | Where-Object { $_ -like 'public/*' } | Select-Object -First 1)) { throw 'ACP ZIP ungültig: public Ordner fehlt.' }
      if (-not ($names | Where-Object { $_ -like 'lib/*' } | Select-Object -First 1)) { throw 'ACP ZIP ungültig: lib Ordner fehlt.' }
    }
    [void](Add-UiLog "ZIP Validierung erfolgreich: $fileName · $($zip.Entries.Count) Einträge · ${sizeMb} MB")
    return (Normalize-DeployKind $zipKind)
  } finally { if ($null -ne $zip) { $zip.Dispose() } }
}

function Mask-SecretValue([string]$value, [bool]$full = $false) {
  if ([string]::IsNullOrWhiteSpace($value)) { return '' }
  if ($full -or $value.Length -le 8) { return '********' }
  return ($value.Substring(0,4) + '****' + $value.Substring($value.Length-4))
}

function Write-RedactedJsonFile($obj, [string]$path) {
  try {
    $json = ($obj | ConvertTo-Json -Depth 12)
    [System.IO.File]::WriteAllText($path, $json, $script:Utf8NoBom)
  } catch {}
}


function Copy-RedactedTextFile([string]$source, [string]$destination) {
  try {
    if (-not (Test-Path -LiteralPath $source)) { return }
    $raw = Get-Content -LiteralPath $source -Raw -Encoding UTF8
    [System.IO.File]::WriteAllText($destination, (Redact-SensitiveText $raw), $script:Utf8NoBom)
  } catch {
    try { Copy-Item -LiteralPath $source -Destination $destination -Force -ErrorAction SilentlyContinue } catch {}
  }
}

function Copy-RedactedLogTree([string]$sourceDir, [string]$targetDir) {
  try {
    if (-not (Test-Path -LiteralPath $sourceDir)) { return }
    Get-ChildItem -LiteralPath $sourceDir -File -Recurse -ErrorAction SilentlyContinue | ForEach-Object {
      $rel = $_.FullName.Substring($sourceDir.Length).TrimStart('\','/')
      $dst = Join-Path $targetDir $rel
      New-Item -ItemType Directory -Force -Path (Split-Path -Parent $dst) | Out-Null
      Copy-RedactedTextFile $_.FullName $dst
    }
  } catch {}
}

function Create-SupportPackage() {
  try {
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $temp = Join-Path ([IO.Path]::GetTempPath()) ("crimson-support-$stamp")
    New-Item -ItemType Directory -Force -Path $temp | Out-Null
    $logTarget = Join-Path $temp 'logs'
    New-Item -ItemType Directory -Force -Path $logTarget | Out-Null
    if (Test-Path -LiteralPath $script:LogDir) { Copy-RedactedLogTree $script:LogDir $logTarget }
    if (Test-Path -LiteralPath $script:HistoryFile) { Copy-RedactedTextFile $script:HistoryFile (Join-Path $temp 'deploy-history.json') }
    if (Test-Path -LiteralPath $script:DeployStateFileConfig) { Copy-RedactedTextFile $script:DeployStateFileConfig (Join-Path $temp 'deploy-state.json') }
    if (Test-Path -LiteralPath $script:ServerHealthFile) { Copy-RedactedTextFile $script:ServerHealthFile (Join-Path $temp 'server-health.json') }

    if (Test-Path -LiteralPath $script:ConfigPath) {
      $cfg = Get-Content -LiteralPath $script:ConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json
      foreach ($srv in @($cfg.servers)) {
        if ($srv.PSObject.Properties.Name -contains 'privateKey') { $srv.privateKey = '<redacted>' }
        if ($srv.PSObject.Properties.Name -contains 'privateKeyContent') { $srv.privateKeyContent = '<redacted>' }
      }
      Write-RedactedJsonFile $cfg (Join-Path $temp 'servers.redacted.json')
    }

    if (Test-Path -LiteralPath $script:SettingsFile) {
      $settings = Get-Content -LiteralPath $script:SettingsFile -Raw -Encoding UTF8 | ConvertFrom-Json
      foreach ($name in @('minioSecretKey','secretKey','accessSecret','password','token')) {
        if ($settings.PSObject.Properties.Name -contains $name) { $settings.$name = '********' }
      }
      foreach ($name in @('minioAccessKey','accessKey')) {
        if ($settings.PSObject.Properties.Name -contains $name) { $settings.$name = Mask-SecretValue ([string]$settings.$name) $false }
      }
      Write-RedactedJsonFile $settings (Join-Path $temp 'app-settings.redacted.json')
    }

    $sshPath = ''
    $scpPath = ''
    try { $sshPath = (Get-Command 'ssh.exe' -ErrorAction SilentlyContinue).Source } catch {}
    try { $scpPath = (Get-Command 'scp.exe' -ErrorAction SilentlyContinue).Source } catch {}
    $info = @(
      "Crimson Deploy Tool $script:AppVersion",
      "Export: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')",
      "Root: $script:Root",
      "Windows User: $env:USERNAME",
      "OS: $([Environment]::OSVersion.VersionString)",
      "PowerShell: $($PSVersionTable.PSVersion.ToString())",
      "ssh.exe: $sshPath",
      "scp.exe: $scpPath"
    ) -join [Environment]::NewLine
    [System.IO.File]::WriteAllText((Join-Path $temp 'diagnose.txt'), $info, $script:Utf8NoBom)
    $zipPath = Join-Path $script:LogDir ("crimson-support-$stamp.zip")
    if (Test-Path -LiteralPath $zipPath) { Remove-Item -LiteralPath $zipPath -Force }
    [System.IO.Compression.ZipFile]::CreateFromDirectory($temp, $zipPath)
    Remove-Item -LiteralPath $temp -Recurse -Force -ErrorAction SilentlyContinue
    Add-UiLog "Support Paket erstellt: $zipPath"
    Show-CrimsonToast 'Support Paket erstellt' ([IO.Path]::GetFileName($zipPath)) 'success'
    Start-Process explorer.exe -ArgumentList ('/select,"' + $zipPath + '"')
  } catch { Add-UiLog ('FEHLER: Support Paket konnte nicht erstellt werden: ' + $_.Exception.Message); Show-CrimsonToast 'Support Paket Fehler' $_.Exception.Message 'error' }
}

function Get-AppPathForKind([string]$kind) {
  if ($kind -eq 'hub') { return '/opt/cr1ms0n-next' }
  if ($kind -eq 'acp') { return '/opt/crimson-acp' }
  return ''
}

function Build-PreflightScript([string]$kind) {
  $appPath = Get-AppPathForKind $kind
  $serviceCheck = if ($kind -eq 'hub') { 'systemctl status cr1ms0n-next.service --no-pager || true' } else { 'pm2 status || true' }
  $writeCheck = if ($kind -eq 'hub') { 'touch /tmp/crimson-preflight-hub.tmp && rm -f /tmp/crimson-preflight-hub.tmp' } else { 'touch /tmp/crimson-preflight-acp.tmp && rm -f /tmp/crimson-preflight-acp.tmp' }
@"
set -Eeuo pipefail
APP='$appPath'
log(){ printf '\n[%s] %s\n' "`$(date +%H:%M:%S)" "`$*"; }
fail(){ echo "FEHLER: `$*"; exit 1; }
warn(){ echo "WARNUNG: `$*"; }
log "Preflight Check startet"
log "Zielordner: `$APP"
for cmd in unzip rsync npm curl df du; do if command -v "`$cmd" >/dev/null 2>&1; then log "OK: Befehl vorhanden: `$cmd"; else warn "Befehl fehlt: `$cmd"; fi; done
[ -d "`$APP" ] || fail "Zielordner fehlt: `$APP"
[ -w "`$APP" ] || warn "Zielordner ist für aktuellen User nicht direkt beschreibbar, root kann dennoch funktionieren."
$writeCheck || warn "Remote Temp Schreibtest nicht erfolgreich. Deploy kann trotzdem funktionieren, wenn Rechte passen."
log "Speicherplatz"
df -h "`$APP" || df -h || true
log "Node Version"
node -v || warn "Node konnte nicht geprüft werden"
log "NPM Version"
npm -v || warn "NPM konnte nicht geprüft werden"
log "Service Status"
$serviceCheck
log "Preflight Status: success"
"@
}

function Build-RollbackScript([string]$kind, [string]$version) {
  $version = $version.Trim()
  if ($kind -eq 'hub') {
    $versionQ = Shell-Quote $version
$s = @"
set -Eeuo pipefail
APP=/opt/cr1ms0n-next
VERSION=$versionQ
log(){ printf '\n[%s] %s\n' "`$(date +%H:%M:%S)" "`$*"; }
fail(){ echo "FEHLER: `$*"; exit 1; }
log "Rollback Hub startet"
if [ -n "`$VERSION" ]; then
  BACKUP=`$(ls -dt /opt/cr1ms0n-next-backup-`$VERSION-* 2>/dev/null | head -1 || true)
else
  BACKUP=`$(ls -dt /opt/cr1ms0n-next-backup-* 2>/dev/null | head -1 || true)
fi
[ -n "`$BACKUP" ] || fail "Kein passendes Hub Backup gefunden"
log "Backup gewählt: `$BACKUP"
SAFETY="/opt/cr1ms0n-next-before-rollback-`$(date +%Y%m%d-%H%M%S)"
cp -a "`$APP" "`$SAFETY"
log "Sicherheitskopie vor Rollback: `$SAFETY"
rsync -a --delete --exclude='.env' --exclude='.env.local' --exclude='storage/' --exclude='uploads/' "`$BACKUP"/ "`$APP"/
systemctl restart cr1ms0n-next.service
sleep 3
systemctl is-active --quiet cr1ms0n-next.service || fail "Hub Service nach Rollback nicht aktiv"
log "Health Check Hub"
CODE=`$(curl -sS -o /dev/null -w "%{http_code}" --max-time 20 https://next.cr1ms0n.xyz/ || true)
case "`$CODE" in 2*|3*) log "Health Check erfolgreich: HTTP `$CODE" ;; *) fail "Health Check fehlgeschlagen: HTTP `$CODE" ;; esac
log "Rollback Status: success"
"@
    return $s
  }
  $versionQ = Shell-Quote $version
$s = @"
set -Eeuo pipefail
APP=/opt/crimson-acp
VERSION=$versionQ
log(){ printf '\n[%s] %s\n' "`$(date +%H:%M:%S)" "`$*"; }
fail(){ echo "FEHLER: `$*"; exit 1; }
log "Rollback ACP startet"
if [ -n "`$VERSION" ]; then
  BACKUP=`$(ls -dt /opt/crimson-acp-backup-`$VERSION-* 2>/dev/null | head -1 || true)
else
  BACKUP=`$(ls -dt /opt/crimson-acp-backup-* 2>/dev/null | head -1 || true)
fi
[ -n "`$BACKUP" ] || fail "Kein passendes ACP Backup gefunden"
log "Backup gewählt: `$BACKUP"
SAFETY="/opt/crimson-acp-before-rollback-`$(date +%Y%m%d-%H%M%S)"
cp -a "`$APP" "`$SAFETY"
log "Sicherheitskopie vor Rollback: `$SAFETY"
rsync -a --delete --exclude='.env' --exclude='runtime/' --exclude='data/' --exclude='uploads/' "`$BACKUP"/ "`$APP"/
pm2 restart crimson-acp --update-env
pm2 save
sleep 3
pm2 describe crimson-acp | grep -qi "online" || fail "ACP Prozess nach Rollback nicht online"
log "Health Check ACP"
CODE=`$(curl -sS -o /dev/null -w "%{http_code}" --max-time 20 https://acp.cr1ms0n.xyz/ || true)
case "`$CODE" in 2*|3*) log "Health Check erfolgreich: HTTP `$CODE" ;; *) fail "Health Check fehlgeschlagen: HTTP `$CODE" ;; esac
log "Rollback Status: success"
"@
  return $s
}
function Show-ServerManagerWindow() {
  try {
    $win = [Windows.Window]::new()
    $win.Title = 'Server verwalten'
    $win.Width = 1040
    $win.Height = 720
    $win.MinWidth = 940
    $win.MinHeight = 640
    $win.WindowStartupLocation = 'CenterOwner'
    $win.Owner = $script:Window
    $win.Background = New-Brush '#04070F'
    Apply-CrimsonSubWindowStyle $win

    $state = [pscustomobject]@{
      Servers = [System.Collections.ArrayList]::new()
      SelectedIndex = -1
      Kind = 'hub'
      SelectedCard = $null
    }
    foreach ($srv in @($script:Servers)) {
      $copy = [pscustomobject]@{
        id = Get-ObjectPropertyString $srv 'id'
        label = Get-ObjectPropertyString $srv 'label'
        kind = Get-ServerKind $srv
        host = Get-ObjectPropertyString $srv 'host'
        port = [int](Get-ObjectPropertyValue $srv 'port' 22)
        username = Get-ObjectPropertyString $srv 'username' 'root'
        privateKeyPath = Get-ObjectPropertyString $srv 'privateKeyPath'
      }
      [void]$state.Servers.Add($copy)
    }

    function New-SMBrush([string]$hex) { return New-Brush $hex }
    function New-SMText([string]$text, [double]$size, [string]$color, [string]$family = 'DM Sans, Segoe UI', $weight = $null) {
      $t = [Windows.Controls.TextBlock]::new()
      $t.Text = $text
      $t.FontSize = $size
      $t.Foreground = New-SMBrush $color
      $t.FontFamily = [Windows.Media.FontFamily]::new($family)
      $t.TextTrimming = 'CharacterEllipsis'
      if ($null -ne $weight) { $t.FontWeight = $weight }
      return $t
    }
    function New-SMCard([double]$radius = 14) {
      $b = [Windows.Controls.Border]::new()
      $b.CornerRadius = [Windows.CornerRadius]::new($radius)
      $b.Background = New-SMBrush '#0D1528'
      $b.BorderBrush = New-SMBrush '#183148'
      $b.BorderThickness = [Windows.Thickness]::new(1)
      $b.Padding = [Windows.Thickness]::new(16)
      return $b
    }
    function New-SMInput([string]$text = '') {
      $tb = [Windows.Controls.TextBox]::new()
      $tb.Text = $text
      $tb.Height = 40
      $tb.MinWidth = 0
      $tb.HorizontalAlignment = 'Stretch'
      $tb.Background = New-SMBrush '#07111D'
      $tb.Foreground = New-SMBrush '#DDE6F0'
      $tb.CaretBrush = New-SMBrush '#22D3EE'
      $tb.BorderBrush = New-SMBrush '#224F63'
      $tb.BorderThickness = [Windows.Thickness]::new(1)
      $tb.FontFamily = [Windows.Media.FontFamily]::new('JetBrains Mono, Cascadia Mono, Consolas')
      $tb.FontSize = 12
      $tb.Padding = [Windows.Thickness]::new(12,7,12,7)
      $tb.VerticalContentAlignment = 'Center'
      $tb.TextWrapping = 'NoWrap'
      $tb.HorizontalScrollBarVisibility = 'Auto'
      $tb.VerticalScrollBarVisibility = 'Disabled'
      return $tb
    }
    function New-SMButton([string]$text, [string]$mode = 'secondary', [double]$width = 110) {
      $b = [Windows.Controls.Button]::new()
      $b.Content = $text
      $b.Width = $width
      $b.Height = 36
      $b.Margin = [Windows.Thickness]::new(0,0,8,0)
      $b.FontFamily = [Windows.Media.FontFamily]::new('DM Sans, Segoe UI')
      $b.FontSize = 12
      $b.FontWeight = [Windows.FontWeights]::SemiBold
      $b.Padding = [Windows.Thickness]::new(12,0,12,0)
      $b.Cursor = [Windows.Input.Cursors]::Hand
      switch ($mode) {
        'primary' { $b.Background = New-SMBrush '#0891B2'; $b.Foreground = New-SMBrush '#030C18'; $b.BorderBrush = New-SMBrush '#22D3EE' }
        'danger'  { $b.Background = New-SMBrush '#1A0B12'; $b.Foreground = New-SMBrush '#F87171'; $b.BorderBrush = New-SMBrush '#5F1D2A' }
        'ghost'   { $b.Background = New-SMBrush '#070C18'; $b.Foreground = New-SMBrush '#8FA3BE'; $b.BorderBrush = New-SMBrush '#183148' }
        default   { $b.Background = New-SMBrush '#0D1528'; $b.Foreground = New-SMBrush '#22D3EE'; $b.BorderBrush = New-SMBrush '#224F63' }
      }
      $b.BorderThickness = [Windows.Thickness]::new(1)
      return $b
    }
    function New-SMBadge([string]$text, [string]$mode) {
      $bd = [Windows.Controls.Border]::new()
      $bd.CornerRadius = [Windows.CornerRadius]::new(5)
      $bd.BorderThickness = [Windows.Thickness]::new(1)
      $bd.Padding = [Windows.Thickness]::new(7,2,7,2)
      $bd.Margin = [Windows.Thickness]::new(0,0,6,0)
      $t = New-SMText $text 9 '#8FA3BE' 'JetBrains Mono, Cascadia Mono, Consolas' ([Windows.FontWeights]::SemiBold)
      switch ($mode) {
        'online' { $bd.Background = New-SMBrush '#1A10B981'; $bd.BorderBrush = New-SMBrush '#4710B981'; $t.Foreground = New-SMBrush '#34D399' }
        'offline' { $bd.Background = New-SMBrush '#1AEF4444'; $bd.BorderBrush = New-SMBrush '#47EF4444'; $t.Foreground = New-SMBrush '#F87171' }
        'key' { $bd.Background = New-SMBrush '#1406B6D4'; $bd.BorderBrush = New-SMBrush '#1F22D3EE'; $t.Foreground = New-SMBrush '#22D3EE' }
        'warn' { $bd.Background = New-SMBrush '#1AF59E0B'; $bd.BorderBrush = New-SMBrush '#55F59E0B'; $t.Foreground = New-SMBrush '#FBBF24' }
        default { $bd.Background = New-SMBrush '#0AFFFFFF'; $bd.BorderBrush = New-SMBrush '#1F22D3EE'; $t.Foreground = New-SMBrush '#8FA3BE' }
      }
      $bd.Child = $t
      return $bd
    }

    $root = [Windows.Controls.Grid]::new()
    $root.Margin = [Windows.Thickness]::new(22)
    $root.RowDefinitions.Add((New-Object Windows.Controls.RowDefinition -Property @{ Height = [Windows.GridLength]::new(72) })) | Out-Null
    $root.RowDefinitions.Add((New-Object Windows.Controls.RowDefinition -Property @{ Height = [Windows.GridLength]::new(1, [Windows.GridUnitType]::Star) })) | Out-Null
    $root.RowDefinitions.Add((New-Object Windows.Controls.RowDefinition -Property @{ Height = [Windows.GridLength]::new(58) })) | Out-Null

    $header = New-SMCard 16
    $header.Padding = [Windows.Thickness]::new(18,14,18,14)
    $header.Background = New-LinearBrushVertical '#111E36' '#08101F'
    $hStack = [Windows.Controls.StackPanel]::new()
    $hTitle = New-SMText 'Server Verwaltung' 22 '#DDE6F0' 'Rajdhani, Segoe UI' ([Windows.FontWeights]::Bold)
    $hSub = New-SMText 'Verwalte Hub und ACP Ziele, SSH Zugang und Private Key Pfade ohne Neustart.' 12 '#8FA3BE'
    $hStack.Children.Add($hTitle) | Out-Null
    $hStack.Children.Add($hSub) | Out-Null
    $header.Child = $hStack
    [Windows.Controls.Grid]::SetRow($header,0)
    $root.Children.Add($header) | Out-Null

    $body = [Windows.Controls.Grid]::new()
    $body.Margin = [Windows.Thickness]::new(0,18,0,0)
    $body.ColumnDefinitions.Add((New-Object Windows.Controls.ColumnDefinition -Property @{ Width = [Windows.GridLength]::new(320) })) | Out-Null
    $body.ColumnDefinitions.Add((New-Object Windows.Controls.ColumnDefinition -Property @{ Width = [Windows.GridLength]::new(22) })) | Out-Null
    $body.ColumnDefinitions.Add((New-Object Windows.Controls.ColumnDefinition -Property @{ Width = [Windows.GridLength]::new(1, [Windows.GridUnitType]::Star) })) | Out-Null
    [Windows.Controls.Grid]::SetRow($body,1)
    $root.Children.Add($body) | Out-Null

    $leftCard = New-SMCard 16
    $leftGrid = [Windows.Controls.Grid]::new()
    $leftGrid.RowDefinitions.Add((New-Object Windows.Controls.RowDefinition -Property @{ Height = [Windows.GridLength]::new(42) })) | Out-Null
    $leftGrid.RowDefinitions.Add((New-Object Windows.Controls.RowDefinition -Property @{ Height = [Windows.GridLength]::new(1, [Windows.GridUnitType]::Star) })) | Out-Null
    $leftHeader = New-SMText 'Zielserver' 16 '#DDE6F0' 'Rajdhani, Segoe UI' ([Windows.FontWeights]::Bold)
    [Windows.Controls.Grid]::SetRow($leftHeader,0)
    $leftGrid.Children.Add($leftHeader) | Out-Null
    $serverCards = [Windows.Controls.StackPanel]::new()
    $serverCards.Margin = [Windows.Thickness]::new(0,2,4,0)
    $sv = [Windows.Controls.ScrollViewer]::new()
    $sv.VerticalScrollBarVisibility = 'Auto'
    $sv.HorizontalScrollBarVisibility = 'Disabled'
    $sv.Content = $serverCards
    [Windows.Controls.Grid]::SetRow($sv,1)
    $leftGrid.Children.Add($sv) | Out-Null
    $leftCard.Child = $leftGrid
    [Windows.Controls.Grid]::SetColumn($leftCard,0)
    $body.Children.Add($leftCard) | Out-Null

    $editorCard = New-SMCard 16
    [Windows.Controls.Grid]::SetColumn($editorCard,2)
    $editorScroll = [Windows.Controls.ScrollViewer]::new()
    $editorScroll.VerticalScrollBarVisibility = 'Auto'
    $editorScroll.HorizontalScrollBarVisibility = 'Disabled'
    $editorPanel = [Windows.Controls.StackPanel]::new()
    $editorPanel.Margin = [Windows.Thickness]::new(0,0,6,0)
    $editorScroll.Content = $editorPanel
    $editorCard.Child = $editorScroll
    $body.Children.Add($editorCard) | Out-Null

    $editorPanel.Children.Add((New-SMText 'Editor' 18 '#DDE6F0' 'Rajdhani, Segoe UI' ([Windows.FontWeights]::Bold))) | Out-Null
    $editorInfo = New-SMText 'Änderungen werden nach Speichern direkt in die Haupt UI geladen.' 12 '#8FA3BE'
    $editorInfo.Margin = [Windows.Thickness]::new(0,2,0,16)
    $editorPanel.Children.Add($editorInfo) | Out-Null

    $fields = @{}
    function Add-SMField([string]$label, [string]$name, [string]$default = '') {
      $wrap = [Windows.Controls.StackPanel]::new()
      $wrap.Margin = [Windows.Thickness]::new(0,0,0,12)
      $lbl = New-SMText $label 11 '#8FA3BE' 'DM Sans, Segoe UI' ([Windows.FontWeights]::SemiBold)
      $lbl.Margin = [Windows.Thickness]::new(0,0,0,5)
      $tb = New-SMInput $default
      $wrap.Children.Add($lbl) | Out-Null
      $wrap.Children.Add($tb) | Out-Null
      $editorPanel.Children.Add($wrap) | Out-Null
      $fields[$name] = $tb
    }
    Add-SMField 'ID' 'id'
    Add-SMField 'Label' 'label'

    $typeWrap = [Windows.Controls.StackPanel]::new()
    $typeWrap.Margin = [Windows.Thickness]::new(0,0,0,12)
    $typeWrap.Children.Add((New-SMText 'Typ' 11 '#8FA3BE' 'DM Sans, Segoe UI' ([Windows.FontWeights]::SemiBold))) | Out-Null
    $seg = [Windows.Controls.Grid]::new()
    $seg.Margin = [Windows.Thickness]::new(0,5,0,0)
    $seg.ColumnDefinitions.Add((New-Object Windows.Controls.ColumnDefinition -Property @{ Width = [Windows.GridLength]::new(1, [Windows.GridUnitType]::Star) })) | Out-Null
    $seg.ColumnDefinitions.Add((New-Object Windows.Controls.ColumnDefinition -Property @{ Width = [Windows.GridLength]::new(10) })) | Out-Null
    $seg.ColumnDefinitions.Add((New-Object Windows.Controls.ColumnDefinition -Property @{ Width = [Windows.GridLength]::new(1, [Windows.GridUnitType]::Star) })) | Out-Null
    $hubTypeBtn = New-SMButton 'Hub' 'secondary' 120
    $acpTypeBtn = New-SMButton 'ACP' 'secondary' 120
    $hubTypeBtn.HorizontalAlignment = 'Stretch'; $hubTypeBtn.Width = [double]::NaN
    $acpTypeBtn.HorizontalAlignment = 'Stretch'; $acpTypeBtn.Width = [double]::NaN
    [Windows.Controls.Grid]::SetColumn($hubTypeBtn,0)
    [Windows.Controls.Grid]::SetColumn($acpTypeBtn,2)
    $seg.Children.Add($hubTypeBtn) | Out-Null
    $seg.Children.Add($acpTypeBtn) | Out-Null
    $typeWrap.Children.Add($seg) | Out-Null
    $editorPanel.Children.Add($typeWrap) | Out-Null

    Add-SMField 'Host' 'host'
    Add-SMField 'Port' 'port' '22'
    Add-SMField 'Username' 'username' 'root'

    $keyWrap = [Windows.Controls.StackPanel]::new()
    $keyWrap.Margin = [Windows.Thickness]::new(0,0,0,12)
    $keyWrap.Children.Add((New-SMText 'Private Key Pfad' 11 '#8FA3BE' 'DM Sans, Segoe UI' ([Windows.FontWeights]::SemiBold))) | Out-Null
    $keyGrid = [Windows.Controls.Grid]::new()
    $keyGrid.Margin = [Windows.Thickness]::new(0,5,0,0)
    $keyGrid.ColumnDefinitions.Add((New-Object Windows.Controls.ColumnDefinition -Property @{ Width = [Windows.GridLength]::new(1, [Windows.GridUnitType]::Star) })) | Out-Null
    $keyGrid.ColumnDefinitions.Add((New-Object Windows.Controls.ColumnDefinition -Property @{ Width = [Windows.GridLength]::new(10) })) | Out-Null
    $keyGrid.ColumnDefinitions.Add((New-Object Windows.Controls.ColumnDefinition -Property @{ Width = [Windows.GridLength]::new(94) })) | Out-Null
    $keyTb = New-SMInput ''
    $keyBtn = New-SMButton 'Key wählen' 'secondary' 94
    $keyBtn.Margin = [Windows.Thickness]::new(0)
    [Windows.Controls.Grid]::SetColumn($keyTb,0)
    [Windows.Controls.Grid]::SetColumn($keyBtn,2)
    $keyGrid.Children.Add($keyTb) | Out-Null
    $keyGrid.Children.Add($keyBtn) | Out-Null
    $fields['privateKeyPath'] = $keyTb
    $keyWrap.Children.Add($keyGrid) | Out-Null
    $keyStatusText = New-SMText 'Key Status noch nicht geprüft.' 11 '#8FA3BE' 'JetBrains Mono, Cascadia Mono, Consolas'
    $keyStatusText.Margin = [Windows.Thickness]::new(0,7,0,0)
    $keyWrap.Children.Add($keyStatusText) | Out-Null
    $editorPanel.Children.Add($keyWrap) | Out-Null

    $messageBoxBorder = [Windows.Controls.Border]::new()
    $messageBoxBorder.CornerRadius = [Windows.CornerRadius]::new(8)
    $messageBoxBorder.Background = New-SMBrush '#07111D'
    $messageBoxBorder.BorderBrush = New-SMBrush '#183148'
    $messageBoxBorder.BorderThickness = [Windows.Thickness]::new(1)
    $messageBoxBorder.Padding = [Windows.Thickness]::new(12,8,12,8)
    $messageBoxBorder.Margin = [Windows.Thickness]::new(0,4,0,0)
    $messageText = New-SMText 'Bereit.' 12 '#8FA3BE'
    $messageBoxBorder.Child = $messageText
    $editorPanel.Children.Add($messageBoxBorder) | Out-Null

    function Set-SMMessage([string]$message, [string]$mode = 'info') {
      $messageText.Text = $message
      switch ($mode) {
        'ok' { $messageText.Foreground = New-SMBrush '#34D399'; $messageBoxBorder.BorderBrush = New-SMBrush '#4710B981'; $messageBoxBorder.Background = New-SMBrush '#081E1A' }
        'warn' { $messageText.Foreground = New-SMBrush '#FBBF24'; $messageBoxBorder.BorderBrush = New-SMBrush '#55F59E0B'; $messageBoxBorder.Background = New-SMBrush '#1B1609' }
        'error' { $messageText.Foreground = New-SMBrush '#F87171'; $messageBoxBorder.BorderBrush = New-SMBrush '#5F1D2A'; $messageBoxBorder.Background = New-SMBrush '#1A0B12' }
        default { $messageText.Foreground = New-SMBrush '#8FA3BE'; $messageBoxBorder.BorderBrush = New-SMBrush '#183148'; $messageBoxBorder.Background = New-SMBrush '#07111D' }
      }
    }
    function Set-SMKind([string]$kind) {
      $normalized = Normalize-DeployKind $kind
      if ($normalized -ne 'hub' -and $normalized -ne 'acp') { $normalized = 'hub' }
      $state.Kind = $normalized
      foreach ($btn in @($hubTypeBtn, $acpTypeBtn)) {
        $btn.Background = New-SMBrush '#0D1528'
        $btn.Foreground = New-SMBrush '#8FA3BE'
        $btn.BorderBrush = New-SMBrush '#224F63'
        $btn.Effect = $null
      }
      $activeBtn = if ($state.Kind -eq 'hub') { $hubTypeBtn } else { $acpTypeBtn }
      $activeBtn.Background = New-SMBrush '#111E36'
      $activeBtn.Foreground = New-SMBrush '#22D3EE'
      $activeBtn.BorderBrush = New-SMBrush '#8C22D3EE'
      $activeBtn.Effect = New-Object Windows.Media.Effects.DropShadowEffect -Property @{ Color = [Windows.Media.ColorConverter]::ConvertFromString('#06B6D4'); BlurRadius = 10; ShadowDepth = 0; Opacity = 0.28 }
    }
    function Test-SMKeyPath() {
      $path = [string]$fields['privateKeyPath'].Text
      $resolved = Resolve-KeyPath $path $script:Root
      if ([string]::IsNullOrWhiteSpace($resolved)) { $keyStatusText.Text = 'Key fehlt'; $keyStatusText.Foreground = New-SMBrush '#F87171'; return $false }
      if (Test-Path -LiteralPath $resolved) { $keyStatusText.Text = 'Key OK · ' + $resolved; $keyStatusText.Foreground = New-SMBrush '#34D399'; return $true }
      $keyStatusText.Text = 'Key fehlt oder Pfad ungültig · ' + $resolved
      $keyStatusText.Foreground = New-SMBrush '#FBBF24'
      return $false
    }
    function Load-SMServerToEditor($srv) {
      if ($null -eq $srv) { return }
      $fields['id'].Text = Get-ObjectPropertyString $srv 'id'
      $fields['label'].Text = Get-ObjectPropertyString $srv 'label'
      Set-SMKind (Get-ServerKind $srv)
      $fields['host'].Text = Get-ObjectPropertyString $srv 'host'
      $fields['port'].Text = [string](Get-ObjectPropertyValue $srv 'port' 22)
      $fields['username'].Text = Get-ObjectPropertyString $srv 'username' 'root'
      $fields['privateKeyPath'].Text = Get-ObjectPropertyString $srv 'privateKeyPath'
      [void](Test-SMKeyPath)
      Set-SMMessage 'Server geladen.' 'info'
    }
    function New-SMServerCard($srv, [int]$index) {
      $btn = [Windows.Controls.Button]::new()
      $btn.Tag = $index
      $btn.HorizontalAlignment = 'Stretch'
      $btn.Margin = [Windows.Thickness]::new(0,0,0,10)
      $btn.Background = New-SMBrush $(if($index -eq $state.SelectedIndex){'#111E36'}else{'#0A1020'})
      $btn.BorderBrush = New-SMBrush $(if($index -eq $state.SelectedIndex){'#8C22D3EE'}else{'#183148'})
      $btn.BorderThickness = [Windows.Thickness]::new(1)
      $btn.Padding = [Windows.Thickness]::new(0)
      $btn.Cursor = [Windows.Input.Cursors]::Hand
      if ($index -eq $state.SelectedIndex) { $btn.Effect = New-Object Windows.Media.Effects.DropShadowEffect -Property @{ Color = [Windows.Media.ColorConverter]::ConvertFromString('#06B6D4'); BlurRadius = 12; ShadowDepth = 0; Opacity = 0.25 } }
      $shell = [Windows.Controls.Border]::new()
      $shell.CornerRadius = [Windows.CornerRadius]::new(10)
      $shell.Padding = [Windows.Thickness]::new(12,10,12,10)
      $grid = [Windows.Controls.Grid]::new()
      $grid.RowDefinitions.Add((New-Object Windows.Controls.RowDefinition -Property @{ Height = [Windows.GridLength]::new(30) })) | Out-Null
      $grid.RowDefinitions.Add((New-Object Windows.Controls.RowDefinition -Property @{ Height = [Windows.GridLength]::new(25) })) | Out-Null
      $grid.RowDefinitions.Add((New-Object Windows.Controls.RowDefinition -Property @{ Height = [Windows.GridLength]::new(20) })) | Out-Null
      $top = [Windows.Controls.Grid]::new()
      $top.ColumnDefinitions.Add((New-Object Windows.Controls.ColumnDefinition -Property @{ Width = [Windows.GridLength]::new(30) })) | Out-Null
      $top.ColumnDefinitions.Add((New-Object Windows.Controls.ColumnDefinition -Property @{ Width = [Windows.GridLength]::new(1, [Windows.GridUnitType]::Star) })) | Out-Null
      $kind = Get-ServerKind $srv
      $iconShell = [Windows.Controls.Border]::new(); $iconShell.Width = 24; $iconShell.Height = 24; $iconShell.CornerRadius = [Windows.CornerRadius]::new(6); $iconShell.Background = New-SMBrush '#1406B6D4'; $iconShell.BorderBrush = New-SMBrush '#1F22D3EE'; $iconShell.BorderThickness = [Windows.Thickness]::new(1)
      $ic = New-SMText $(if($kind -eq 'hub'){[string][char]0xE774}elseif($kind -eq 'acp'){[string][char]0xE713}else{[string][char]0xE968}) 13 '#22D3EE' 'Segoe MDL2 Assets'
      $ic.HorizontalAlignment='Center'; $ic.VerticalAlignment='Center'; $iconShell.Child=$ic
      [Windows.Controls.Grid]::SetColumn($iconShell,0)
      $title = New-SMText (Get-ObjectPropertyString $srv 'label' 'Server') 14 '#DDE6F0' 'Rajdhani, Segoe UI' ([Windows.FontWeights]::Bold)
      $title.VerticalAlignment='Center'; [Windows.Controls.Grid]::SetColumn($title,1)
      $top.Children.Add($iconShell)|Out-Null; $top.Children.Add($title)|Out-Null
      [Windows.Controls.Grid]::SetRow($top,0); $grid.Children.Add($top)|Out-Null
      $badges = [Windows.Controls.WrapPanel]::new()
      $health = Get-ServerHealthStatus $srv
      $badges.Children.Add((New-SMBadge $kind.ToUpperInvariant() 'type'))|Out-Null
      if ($health -eq 'online') { $badges.Children.Add((New-SMBadge '● Online' 'online'))|Out-Null } else { $badges.Children.Add((New-SMBadge '● Offline' 'offline'))|Out-Null }
      if ((Get-KeyStatusText $srv) -eq 'Key OK') { $badges.Children.Add((New-SMBadge 'Key OK' 'key'))|Out-Null } else { $badges.Children.Add((New-SMBadge 'Key fehlt' 'warn'))|Out-Null }
      [Windows.Controls.Grid]::SetRow($badges,1); $grid.Children.Add($badges)|Out-Null
      $portValue = [int](Get-ObjectPropertyValue $srv 'port' 22)
      $hostLine = ('{0} · {1}@{2}:{3}' -f $kind.ToUpperInvariant(), (Get-ObjectPropertyString $srv 'username' 'root'), (Get-ObjectPropertyString $srv 'host'), $portValue)
      $hostText = New-SMText $hostLine 9 '#4A5E7A' 'JetBrains Mono, Cascadia Mono, Consolas'
      [Windows.Controls.Grid]::SetRow($hostText,2); $grid.Children.Add($hostText)|Out-Null
      $shell.Child = $grid
      $btn.Content = $shell
      $btn.Add_Click({
        $state.SelectedIndex = [int]$this.Tag
        Render-SMServerCards
        Load-SMServerToEditor $state.Servers[$state.SelectedIndex]
      })
      return $btn
    }
    function Render-SMServerCards() {
      $serverCards.Children.Clear()
      if ($state.Servers.Count -eq 0) {
        $empty = New-SMCard 10
        $empty.Background = New-SMBrush '#07111D'
        $empty.Child = New-SMText 'Noch keine Server angelegt.' 12 '#8FA3BE'
        $serverCards.Children.Add($empty) | Out-Null
        return
      }
      for ($i=0; $i -lt $state.Servers.Count; $i++) {
        $serverCards.Children.Add((New-SMServerCard $state.Servers[$i] $i)) | Out-Null
      }
    }
    function Validate-SMEditor() {
      $id = $fields['id'].Text.Trim()
      $label = $fields['label'].Text.Trim()
      $hostName = $fields['host'].Text.Trim()
      $portText = $fields['port'].Text.Trim()
      $username = $fields['username'].Text.Trim()
      if ([string]::IsNullOrWhiteSpace($id)) { Set-SMMessage 'ID darf nicht leer sein.' 'error'; return $null }
      if ([string]::IsNullOrWhiteSpace($label)) { Set-SMMessage 'Label darf nicht leer sein.' 'error'; return $null }
      if ($state.Kind -ne 'hub' -and $state.Kind -ne 'acp') { Set-SMMessage 'Typ muss Hub oder ACP sein.' 'error'; return $null }
      if ([string]::IsNullOrWhiteSpace($hostName)) { Set-SMMessage 'Host darf nicht leer sein.' 'error'; return $null }
      $portValue = 0
      if (-not [int]::TryParse($portText, [ref]$portValue) -or $portValue -lt 1 -or $portValue -gt 65535) { Set-SMMessage 'Port muss eine Zahl zwischen 1 und 65535 sein.' 'error'; return $null }
      if ([string]::IsNullOrWhiteSpace($username)) { Set-SMMessage 'Username darf nicht leer sein.' 'error'; return $null }
      $keyOk = Test-SMKeyPath
      $obj = [pscustomobject]@{
        id = $id
        label = $label
        kind = $state.Kind
        host = $hostName
        port = $portValue
        username = $username
        privateKeyPath = $fields['privateKeyPath'].Text.Trim()
      }
      if (-not $keyOk) { Set-SMMessage 'Gespeichert möglich, aber Private Key fehlt oder Pfad ist ungültig.' 'warn' }
      return $obj
    }
    function Save-SMConfig() {
      $arr = @()
      foreach ($item in $state.Servers) { $arr += $item }
      $obj = [pscustomobject]@{ servers = $arr }
      New-Item -ItemType Directory -Force -Path (Split-Path -Parent $script:ConfigPath) | Out-Null
      [System.IO.File]::WriteAllText($script:ConfigPath, (($obj | ConvertTo-Json -Depth 10)), $script:Utf8NoBom)
      Load-Servers
      Refresh-ServerCardsAfterStateChange
      Add-UiLog 'Server Konfiguration gespeichert und Haupt UI aktualisiert.'
      Show-CrimsonToast 'Server gespeichert' 'Haupt UI wurde aktualisiert.' 'success'
    }

    $hubTypeBtn.Add_Click({ Set-SMKind 'hub' })
    $acpTypeBtn.Add_Click({ Set-SMKind 'acp' })
    $keyBtn.Add_Click({
      $dlg = [Microsoft.Win32.OpenFileDialog]::new()
      $dlg.Title = 'Private Key wählen'
      $dlg.Filter = 'Alle Dateien (*.*)|*.*'
      $dlg.Multiselect = $false
      if ($dlg.ShowDialog($win) -eq $true) { $fields['privateKeyPath'].Text = $dlg.FileName; [void](Test-SMKeyPath) }
    })

    $footer = [Windows.Controls.Grid]::new()
    $footer.Margin = [Windows.Thickness]::new(0,16,0,0)
    $footer.ColumnDefinitions.Add((New-Object Windows.Controls.ColumnDefinition -Property @{ Width = [Windows.GridLength]::new(1, [Windows.GridUnitType]::Star) })) | Out-Null
    $footer.ColumnDefinitions.Add((New-Object Windows.Controls.ColumnDefinition -Property @{ Width = [Windows.GridLength]::Auto })) | Out-Null
    $buttonPanel = [Windows.Controls.StackPanel]::new(); $buttonPanel.Orientation = 'Horizontal'; $buttonPanel.HorizontalAlignment = 'Right'
    $save = New-SMButton 'Speichern' 'primary' 116
    $add = New-SMButton 'Neu' 'secondary' 82
    $delete = New-SMButton 'Löschen' 'danger' 96
    $checkKey = New-SMButton 'Key prüfen' 'secondary' 104
    $close = New-SMButton 'Schließen' 'ghost' 104
    $buttonPanel.Children.Add($save)|Out-Null; $buttonPanel.Children.Add($add)|Out-Null; $buttonPanel.Children.Add($delete)|Out-Null; $buttonPanel.Children.Add($checkKey)|Out-Null; $buttonPanel.Children.Add($close)|Out-Null
    [Windows.Controls.Grid]::SetColumn($buttonPanel,1)
    $footer.Children.Add($buttonPanel)|Out-Null
    [Windows.Controls.Grid]::SetRow($footer,2)
    $root.Children.Add($footer)|Out-Null

    $checkKey.Add_Click({ if (Test-SMKeyPath) { Set-SMMessage 'Private Key wurde gefunden.' 'ok' } else { Set-SMMessage 'Private Key fehlt oder Pfad ist ungültig.' 'warn' } })
    $add.Add_Click({
      $newId = 'server' + ([int]($state.Servers.Count + 1))
      $obj = [pscustomobject]@{ id=$newId; label='Neuer Server'; kind='hub'; host=''; port=22; username='root'; privateKeyPath='' }
      [void]$state.Servers.Add($obj)
      $state.SelectedIndex = $state.Servers.Count - 1
      Render-SMServerCards
      Load-SMServerToEditor $obj
      Set-SMMessage 'Neuer Server angelegt. Bitte Werte ausfüllen und speichern.' 'info'
    })
    $delete.Add_Click({
      if ($state.SelectedIndex -lt 0 -or $state.SelectedIndex -ge $state.Servers.Count) { Set-SMMessage 'Kein Server ausgewählt.' 'warn'; return }
      $srv = $state.Servers[$state.SelectedIndex]
      $label = Get-ObjectPropertyString $srv 'label' 'Server'
      $res = [System.Windows.MessageBox]::Show("Server '$label' wirklich löschen?", 'Server löschen', 'YesNo', 'Warning')
      if ($res -ne 'Yes') { return }
      $state.Servers.RemoveAt($state.SelectedIndex)
      if ($state.Servers.Count -gt 0) { $state.SelectedIndex = [Math]::Min($state.SelectedIndex, $state.Servers.Count - 1) } else { $state.SelectedIndex = -1 }
      Render-SMServerCards
      if ($state.SelectedIndex -ge 0) { Load-SMServerToEditor $state.Servers[$state.SelectedIndex] }
      Save-SMConfig
      Set-SMMessage 'Server gelöscht.' 'ok'
    })
    $save.Add_Click({
      $obj = Validate-SMEditor
      if ($null -eq $obj) { return }
      if ($state.SelectedIndex -lt 0 -or $state.SelectedIndex -ge $state.Servers.Count) { [void]$state.Servers.Add($obj); $state.SelectedIndex = $state.Servers.Count - 1 }
      else { $state.Servers[$state.SelectedIndex] = $obj }
      Save-SMConfig
      Render-SMServerCards
      Set-SMMessage 'Server gespeichert und Haupt UI aktualisiert.' 'ok'
    })
    $close.Add_Click({ $win.Close() })

    if ($state.Servers.Count -gt 0) { $state.SelectedIndex = 0; Load-SMServerToEditor $state.Servers[0] } else { Set-SMKind 'hub'; Set-SMMessage 'Noch keine Server vorhanden.' 'warn' }
    Render-SMServerCards
    $win.Content = $root
    [void]$win.ShowDialog()
  } catch { Add-UiLog ('FEHLER: Server Verwaltung konnte nicht geöffnet werden: ' + $_.Exception.Message) }
}

function Test-CrimsonTcpOnline([string]$hostName, [int]$port, [int]$timeoutMs) {
  $client = $null
  try {
    if ([string]::IsNullOrWhiteSpace($hostName)) { return $false }
    $client = [System.Net.Sockets.TcpClient]::new()
    $async = $client.BeginConnect($hostName, $port, $null, $null)
    if (-not $async.AsyncWaitHandle.WaitOne($timeoutMs, $false)) { return $false }
    $client.EndConnect($async)
    return $true
  } catch { return $false }
  finally { try { if ($client) { $client.Close(); $client.Dispose() } } catch {} }
}

function Test-CrimsonPingOnline([string]$hostName, [int]$timeoutMs) {
  try {
    if ([string]::IsNullOrWhiteSpace($hostName)) { return $false }
    $ping = [System.Net.NetworkInformation.Ping]::new()
    $reply = $ping.Send($hostName, $timeoutMs)
    try { $ping.Dispose() } catch {}
    return ($reply -and $reply.Status -eq [System.Net.NetworkInformation.IPStatus]::Success)
  } catch { return $false }
}

function Test-CrimsonSshOnline($srv, [int]$timeoutMs) {
  $proc = $null
  try {
    $sshCmd = Get-Command ssh.exe -ErrorAction SilentlyContinue
    if (-not $sshCmd) { return $false }
    $hostName = if ($srv.PSObject.Properties.Name -contains 'host' -and $srv.host) { [string]$srv.host } else { '' }
    if ([string]::IsNullOrWhiteSpace($hostName)) { return $false }
    $port = if ($srv.PSObject.Properties.Name -contains 'port' -and $srv.port) { [int]$srv.port } else { 22 }
    $user = if ($srv.PSObject.Properties.Name -contains 'username' -and $srv.username) { [string]$srv.username } else { 'root' }
    $key = Resolve-LocalPath ([string]$srv.privateKeyPath)
    if ([string]::IsNullOrWhiteSpace($key) -or -not (Test-Path -LiteralPath $key)) { return $false }
    $remote = "${user}@${hostName}"
    $psi = [System.Diagnostics.ProcessStartInfo]::new()
    $psi.FileName = $sshCmd.Source
    $args = @('-T','-p',[string]$port,'-i',$key,'-o','BatchMode=yes','-o','PasswordAuthentication=no','-o','NumberOfPasswordPrompts=0','-o','ConnectTimeout=10','-o','ConnectionAttempts=1','-o','ServerAliveInterval=5','-o','ServerAliveCountMax=1','-o','StrictHostKeyChecking=no','-o','LogLevel=ERROR',$remote,'exit 0')
    foreach ($a in $args) { [void]$psi.ArgumentList.Add([string]$a) }
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $proc = [System.Diagnostics.Process]::Start($psi)
    if (-not $proc.WaitForExit($timeoutMs)) { try { $proc.Kill() } catch {}; return $false }
    return ($proc.ExitCode -eq 0)
  } catch { return $false }
  finally { try { if ($proc) { $proc.Dispose() } } catch {} }
}

function Set-ServerHealthForServer($srv, [string]$status) {
  $count = 0
  try {
    foreach ($key in @(Get-ServerIdentityKeys $srv)) {
      $k = ([string]$key).Trim().ToLowerInvariant()
      if (-not [string]::IsNullOrWhiteSpace($k)) {
        $script:ServerHealth[$k] = (New-HealthRecord $status 'mixed')
        $count++
      }
    }
    $id = if ($srv.PSObject.Properties.Name -contains 'id' -and $srv.id) { [string]$srv.id } else { '' }
    $label = if ($srv.PSObject.Properties.Name -contains 'label' -and $srv.label) { [string]$srv.label } else { '' }
    $kind = if ($srv.PSObject.Properties.Name -contains 'kind' -and $srv.kind) { ([string]$srv.kind).ToLowerInvariant() } else { '' }
    $hostName = if ($srv.PSObject.Properties.Name -contains 'host' -and $srv.host) { [string]$srv.host } else { '' }
    foreach ($extra in @($id,$label,$kind,$hostName,"$kind|$id","$kind|$label","$kind|$hostName")) {
      $k = ([string]$extra).Trim().ToLowerInvariant()
      if (-not [string]::IsNullOrWhiteSpace($k)) { $script:ServerHealth[$k] = (New-HealthRecord $status 'mixed'); $count++ }
    }
  } catch {}
  return $count
}

function Start-ServerOnlineChecks() {
  try {
    if (-not $script:Servers -or @($script:Servers).Count -eq 0) { Add-UiLog 'Online Statusprüfung: keine Server geladen.'; return }
    Add-UiLog 'Online Statusprüfung startet.'
    $oldCursor = $script:Window.Cursor
    try { $script:Window.Cursor = [Windows.Input.Cursors]::Wait } catch {}
    $updated = 0
    $checkedCount = 0
    $onlineCount = 0
    foreach ($srv in @($script:Servers)) {
      $checkedCount++
      $label = Get-ServerLabel $srv
      $hostName = if ($srv.PSObject.Properties.Name -contains 'host' -and $srv.host) { [string]$srv.host } else { '' }
      $port = if ($srv.PSObject.Properties.Name -contains 'port' -and $srv.port) { [int]$srv.port } else { 22 }
      $isOnline = $false
      if (-not [string]::IsNullOrWhiteSpace($hostName)) {
        if (Test-CrimsonTcpOnline $hostName $port 4500) { $isOnline = $true }
        elseif (Test-CrimsonSshOnline $srv 12000) { $isOnline = $true }
        elseif (Test-CrimsonPingOnline $hostName 1800) { $isOnline = $true }
      }
      $status = if ($isOnline) { 'online' } else { 'offline' }
      $updated += Set-ServerHealthForServer $srv $status
      if ($isOnline) { $onlineCount++ }
      Add-UiLog ("Online Status: $label = " + $(if($isOnline){'Online'}else{'Offline'}))
    }
    Save-ServerHealthState
    Refresh-ServerCardsAfterStateChange
    Add-UiLog "Online Status geprüft. $checkedCount Server geprüft, $onlineCount online."
  } catch { Add-UiLog ('FEHLER: Online Statusprüfung konnte nicht ausgeführt werden: ' + $_.Exception.Message) }
  finally { try { $script:Window.Cursor = $oldCursor } catch {} }
}

function Confirm-VersionDeployAllowed([string]$zipName, $srv) {
  $newVersion = Version-FromFile $zipName
  $lastVersion = Get-LastServerVersion $srv
  if ([string]::IsNullOrWhiteSpace($lastVersion) -or $lastVersion -eq 'manual' -or $newVersion -eq 'manual') { return $true }
  $cmp = Compare-CrimsonVersion $newVersion $lastVersion
  if ($cmp -gt 0) { return $true }
  $msg = "Achtung: Das ausgewählte Paket ist nicht neuer als die zuletzt deployte Version.`n`nZiel: $(Get-ServerLabel $srv)`nZuletzt deployt: $lastVersion`nAusgewählt: $newVersion`n`nDeploy trotzdem starten?"
  $res = [System.Windows.MessageBox]::Show($msg, 'Deploy Warnung', 'YesNo', 'Warning')
  return ($res -eq 'Yes')
}


function Copy-BackupSourceFile([string]$source, [string]$base, [string]$relativePath) {
  try {
    if ([string]::IsNullOrWhiteSpace($source) -or -not (Test-Path -LiteralPath $source)) { return }
    $target = Join-Path $base $relativePath
    $parent = Split-Path -Parent $target
    if (-not [string]::IsNullOrWhiteSpace($parent)) { New-Item -ItemType Directory -Force -Path $parent | Out-Null }
    Copy-Item -LiteralPath $source -Destination $target -Force
  } catch { try { Add-UiLog ('WARNUNG: Backup Datei konnte nicht kopiert werden: ' + $source + ' · ' + $_.Exception.Message) } catch {} }
}

function Cleanup-ConfigBackupFolder([string]$folder) {
  try {
    if ([string]::IsNullOrWhiteSpace($folder) -or -not (Test-Path -LiteralPath $folder)) { return }
    $keep = Get-AppSettingInt 'keepBackupCount' 10 1
    $files = @(Get-ChildItem -LiteralPath $folder -Filter 'crimson-deploy-tool-config-backup-*.zip' -File -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending)
    if ($files.Count -le $keep) { return }
    $remove = $files | Select-Object -Skip $keep
    foreach ($f in $remove) { try { Remove-Item -LiteralPath $f.FullName -Force } catch {} }
    Add-UiLog "Config Backup Aufbewahrung bereinigt. Behalten: $keep"
  } catch { Add-UiLog ('WARNUNG: Config Backup Aufbewahrung konnte nicht bereinigt werden: ' + $_.Exception.Message) }
}

function Get-ConfigBackupFolder([string]$TargetFolder = '') {
  $folder = $TargetFolder
  if ([string]::IsNullOrWhiteSpace($folder)) { $folder = Get-AppSettingString 'backupFolder' '' }
  if ([string]::IsNullOrWhiteSpace($folder)) { $folder = Join-Path $script:Root 'backups\config' }
  return $folder
}

function New-ConfigBackupPackage([string]$TargetFolder = '', [bool]$Silent = $false) {
  try {
    if ($null -eq $script:AppSettings) { Load-AppSettings | Out-Null }
    $folder = Get-ConfigBackupFolder $TargetFolder
    if ([string]::IsNullOrWhiteSpace($folder)) { throw 'Kein lokaler Backup Ordner gesetzt.' }
    New-Item -ItemType Directory -Force -Path $folder | Out-Null
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $temp = Join-Path ([IO.Path]::GetTempPath()) "crimson-config-backup-$stamp"
    if (Test-Path -LiteralPath $temp) { Remove-Item -LiteralPath $temp -Recurse -Force -ErrorAction SilentlyContinue }
    New-Item -ItemType Directory -Force -Path $temp | Out-Null

    Copy-BackupSourceFile $script:ConfigPath $temp 'config\servers.json'
    Copy-BackupSourceFile $script:DeployStateFileConfig $temp 'config\deploy-state.json'
    Copy-BackupSourceFile $script:SettingsFile $temp 'config\app-settings.json'
    Copy-BackupSourceFile $script:ServerHealthFile $temp 'config\server-health.json'
    Copy-BackupSourceFile $script:HistoryFile $temp 'logs\deploy-history.json'
    Copy-BackupSourceFile $script:DeployStateFile $temp 'logs\deploy-state.json'

    $meta = [pscustomobject]@{
      app = 'Crimson Deploy Tool'
      version = $script:AppVersion
      created = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
      root = $script:Root
      backupType = 'local'
      target = $folder
      files = @('config/servers.json','config/deploy-state.json','config/app-settings.json','config/server-health.json','logs/deploy-history.json','logs/deploy-state.json')
    }
    [System.IO.File]::WriteAllText((Join-Path $temp 'backup.json'), ($meta | ConvertTo-Json -Depth 8), $script:Utf8NoBom)
    $out = Join-Path $folder "crimson-deploy-tool-config-backup-$stamp.zip"
    if (Test-Path -LiteralPath $out) { Remove-Item -LiteralPath $out -Force }
    [System.IO.Compression.ZipFile]::CreateFromDirectory($temp, $out)
    if (-not (Test-Path -LiteralPath $out)) { throw 'Backup ZIP konnte lokal nicht erstellt werden.' }
    $zipCheck = [System.IO.Compression.ZipFile]::OpenRead($out)
    try { if ($zipCheck.Entries.Count -lt 1) { throw 'Backup ZIP wurde erstellt, ist aber leer.' } } finally { $zipCheck.Dispose() }
    Remove-Item -LiteralPath $temp -Recurse -Force -ErrorAction SilentlyContinue
    Cleanup-ConfigBackupFolder $folder
    if ($Silent) { Add-UiLog "Automatisches lokales Config Backup erstellt: $out" } else { Add-UiLog "Lokales Config Backup erstellt: $out"; Show-CrimsonToast 'Config Backup erstellt' ([IO.Path]::GetFileName($out)) 'success' }
    return $out
  } catch {
    $prefix = if ($Silent) { 'WARNUNG: Automatisches lokales Config Backup konnte nicht erstellt werden: ' } else { 'FEHLER: Lokales Config Backup konnte nicht erstellt werden: ' }
    Add-UiLog ($prefix + $_.Exception.Message)
    if (-not $Silent) { Show-CrimsonToast 'Config Backup Fehler' $_.Exception.Message 'error' }
    return $null
  }
}

function Invoke-AutoConfigBackupIfEnabled() {
  try {
    if (-not (Get-AppSettingBool 'autoConfigBackupAfterDeploy' $false)) { return }
    $folder = Get-ConfigBackupFolder ''
    if ([string]::IsNullOrWhiteSpace($folder)) { Add-UiLog 'WARNUNG: Automatisches lokales Config Backup ist aktiv, aber kein Backup Ordner gesetzt.'; return }
    [void](New-ConfigBackupPackage $folder $true)
  } catch { Add-UiLog ('WARNUNG: Automatisches lokales Config Backup konnte nicht gestartet werden: ' + $_.Exception.Message) }
}

function Restore-ConfigBackupPackage() {
  try {
    $dlg = New-Object Microsoft.Win32.OpenFileDialog
    $dlg.Title = 'Config Backup wählen'
    $dlg.Filter = 'Crimson Config Backup (*.zip)|*.zip|Alle Dateien (*.*)|*.*'
    if ($dlg.ShowDialog($script:Window) -ne $true) { return }
    $res = [System.Windows.MessageBox]::Show('Config Backup wirklich wiederherstellen? Die aktuelle Server Config wird vorher gesichert.', 'Config Backup laden', 'YesNo', 'Warning')
    if ($res -ne 'Yes') { return }
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $safety = Join-Path $script:LogDir "config-before-restore-$stamp"
    New-Item -ItemType Directory -Force -Path $safety | Out-Null
    foreach ($file in @($script:ConfigPath, $script:DeployStateFileConfig, $script:SettingsFile, $script:ServerHealthFile, $script:HistoryFile, $script:DeployStateFile)) {
      if (Test-Path -LiteralPath $file) { Copy-Item -LiteralPath $file -Destination (Join-Path $safety ([IO.Path]::GetFileName($file))) -Force }
    }
    $temp = Join-Path ([IO.Path]::GetTempPath()) "crimson-config-restore-$stamp"
    New-Item -ItemType Directory -Force -Path $temp | Out-Null
    [System.IO.Compression.ZipFile]::ExtractToDirectory($dlg.FileName, $temp)

    $serversNested = Join-Path $temp 'config\servers.json'
    $stateNested = Join-Path $temp 'config\deploy-state.json'
    $settingsNested = Join-Path $temp 'config\app-settings.json'
    $healthNested = Join-Path $temp 'config\server-health.json'
    $historyNested = Join-Path $temp 'logs\deploy-history.json'
    $logStateNested = Join-Path $temp 'logs\deploy-state.json'

    if (Test-Path -LiteralPath $serversNested) { Copy-Item -LiteralPath $serversNested -Destination $script:ConfigPath -Force }
    elseif (Test-Path -LiteralPath (Join-Path $temp 'servers.json')) { Copy-Item -LiteralPath (Join-Path $temp 'servers.json') -Destination $script:ConfigPath -Force }

    if (Test-Path -LiteralPath $stateNested) {
      Copy-Item -LiteralPath $stateNested -Destination $script:DeployStateFileConfig -Force
      Copy-Item -LiteralPath $stateNested -Destination $script:DeployStateFile -Force
    } elseif (Test-Path -LiteralPath (Join-Path $temp 'deploy-state.json')) {
      Copy-Item -LiteralPath (Join-Path $temp 'deploy-state.json') -Destination $script:DeployStateFileConfig -Force
      Copy-Item -LiteralPath (Join-Path $temp 'deploy-state.json') -Destination $script:DeployStateFile -Force
    }

    if (Test-Path -LiteralPath $settingsNested) { Copy-Item -LiteralPath $settingsNested -Destination $script:SettingsFile -Force }
    elseif (Test-Path -LiteralPath (Join-Path $temp 'app-settings.json')) { Copy-Item -LiteralPath (Join-Path $temp 'app-settings.json') -Destination $script:SettingsFile -Force }

    if (Test-Path -LiteralPath $healthNested) { Copy-Item -LiteralPath $healthNested -Destination $script:ServerHealthFile -Force }
    elseif (Test-Path -LiteralPath (Join-Path $temp 'server-health.json')) { Copy-Item -LiteralPath (Join-Path $temp 'server-health.json') -Destination $script:ServerHealthFile -Force }

    if (Test-Path -LiteralPath $historyNested) { Copy-Item -LiteralPath $historyNested -Destination $script:HistoryFile -Force }
    elseif (Test-Path -LiteralPath (Join-Path $temp 'deploy-history.json')) { Copy-Item -LiteralPath (Join-Path $temp 'deploy-history.json') -Destination $script:HistoryFile -Force }

    if (Test-Path -LiteralPath $logStateNested) { Copy-Item -LiteralPath $logStateNested -Destination $script:DeployStateFile -Force }
    Remove-Item -LiteralPath $temp -Recurse -Force
    Load-AppSettings | Out-Null
    Load-ServerHealthState
    Load-Servers
    Repair-DeployHistoryAndState
    Refresh-ServerCardsAfterStateChange
    Add-UiLog "Config Backup wiederhergestellt. Sicherheitskopie: $safety"
  } catch { Add-UiLog ('FEHLER: Config Backup konnte nicht geladen werden: ' + $_.Exception.Message) }
}

function Show-SettingsWindow() {
  try {
    if ($null -eq $script:AppSettings) { Load-AppSettings | Out-Null }
    $win = [Windows.Window]::new()
    $win.Title = 'Einstellungen'
    $win.Width = 800
    $win.Height = 720
    $win.MinWidth = 740
    $win.MinHeight = 600
    $win.WindowStartupLocation = 'CenterOwner'
    $win.Owner = $script:Window
    $win.Background = New-Brush '#04070F'
    Apply-CrimsonSubWindowStyle $win
    $win.FontFamily = New-Object Windows.Media.FontFamily('DM Sans, Segoe UI')

    $outer = [Windows.Controls.Grid]::new()
    $outer.Margin = [Windows.Thickness]::new(18)
    $outer.RowDefinitions.Add([Windows.Controls.RowDefinition]::new())
    $buttonRowDef = [Windows.Controls.RowDefinition]::new(); $buttonRowDef.Height = [Windows.GridLength]::new(56); $outer.RowDefinitions.Add($buttonRowDef)

    $scroll = [Windows.Controls.ScrollViewer]::new()
    $scroll.VerticalScrollBarVisibility = 'Auto'
    $scroll.HorizontalScrollBarVisibility = 'Disabled'
    $panel = [Windows.Controls.StackPanel]::new()
    $scroll.Content = $panel
    $outer.Children.Add($scroll) | Out-Null

    function Add-SettingsTitle([string]$text, [string]$sub) {
      $box = [Windows.Controls.Border]::new(); $box.CornerRadius = [Windows.CornerRadius]::new(14); $box.Padding = [Windows.Thickness]::new(18); $box.Margin = [Windows.Thickness]::new(0,0,0,14); $box.Background = New-Brush '#0D1528'; $box.BorderBrush = New-Brush '#183148'; $box.BorderThickness = [Windows.Thickness]::new(1)
      $sp = [Windows.Controls.StackPanel]::new()
      $t = [Windows.Controls.TextBlock]::new(); $t.Text = $text; $t.Foreground = New-Brush '#DDE6F0'; $t.FontSize = 26; $t.FontWeight = [Windows.FontWeights]::Bold; $t.FontFamily = New-Object Windows.Media.FontFamily('Rajdhani, Segoe UI')
      $st = [Windows.Controls.TextBlock]::new(); $st.Text = $sub; $st.Foreground = New-Brush '#8FA3BE'; $st.FontSize = 12; $st.TextWrapping = 'Wrap'; $st.Margin = [Windows.Thickness]::new(0,4,0,0)
      $sp.Children.Add($t)|Out-Null; $sp.Children.Add($st)|Out-Null; $box.Child = $sp; $panel.Children.Add($box)|Out-Null
    }

    function New-Card([string]$title, [string]$sub) {
      $box = [Windows.Controls.Border]::new(); $box.CornerRadius = [Windows.CornerRadius]::new(14); $box.Padding = [Windows.Thickness]::new(18); $box.Margin = [Windows.Thickness]::new(0,0,0,12); $box.Background = New-Brush '#0A1020'; $box.BorderBrush = New-Brush '#183148'; $box.BorderThickness = [Windows.Thickness]::new(1)
      $sp = [Windows.Controls.StackPanel]::new()
      $t = [Windows.Controls.TextBlock]::new(); $t.Text = $title; $t.Foreground = New-Brush '#DDE6F0'; $t.FontSize = 15; $t.FontWeight = [Windows.FontWeights]::Bold; $t.FontFamily = New-Object Windows.Media.FontFamily('Rajdhani, Segoe UI')
      $st = [Windows.Controls.TextBlock]::new(); $st.Text = $sub; $st.Foreground = New-Brush '#8FA3BE'; $st.FontSize = 11; $st.TextWrapping = 'Wrap'; $st.Margin = [Windows.Thickness]::new(0,2,0,12)
      $sp.Children.Add($t)|Out-Null; $sp.Children.Add($st)|Out-Null; $box.Child = $sp; $panel.Children.Add($box)|Out-Null
      return $sp
    }

    function New-SettingCheck([string]$text, [bool]$checked) {
      $cb = [Windows.Controls.CheckBox]::new(); $cb.Content = $text; $cb.Foreground = New-Brush '#DDE6F0'; $cb.FontSize = 12; $cb.IsChecked = $checked; $cb.Margin = [Windows.Thickness]::new(0,0,0,10)
      return $cb
    }

    function New-InputBox([string]$text, [int]$width = 110) {
      $tb = [Windows.Controls.TextBox]::new()
      $tb.Text = $text; $tb.Width = $width; $tb.Height = 38
      $tb.Background = New-Brush '#07111D'; $tb.Foreground = New-Brush '#DDE6F0'; $tb.CaretBrush = New-Brush '#22D3EE'
      $tb.BorderBrush = New-Brush '#224F63'; $tb.BorderThickness=[Windows.Thickness]::new(1)
      $tb.FontFamily = New-Object Windows.Media.FontFamily('JetBrains Mono, Cascadia Mono, Consolas'); $tb.FontSize = 11
      $tb.Padding = [Windows.Thickness]::new(12,7,12,7); $tb.VerticalContentAlignment='Center'; $tb.TextWrapping='NoWrap'; $tb.HorizontalScrollBarVisibility='Auto'
      return $tb
    }
    function New-SettingsRow([string]$label, $control) {
      $row=[Windows.Controls.Grid]::new(); $row.Margin=[Windows.Thickness]::new(0,0,0,8)
      $c1=[Windows.Controls.ColumnDefinition]::new(); $c1.Width=[Windows.GridLength]::new(170); $row.ColumnDefinitions.Add($c1)
      $c2=[Windows.Controls.ColumnDefinition]::new(); $c2.Width=[Windows.GridLength]::new(1,[Windows.GridUnitType]::Star); $row.ColumnDefinitions.Add($c2)
      $t=[Windows.Controls.TextBlock]::new(); $t.Text=$label; $t.Foreground=New-Brush '#8FA3BE'; $t.FontSize=12; $t.VerticalAlignment='Center'
      [Windows.Controls.Grid]::SetColumn($control,1); $control.HorizontalAlignment='Stretch'
      $row.Children.Add($t)|Out-Null; $row.Children.Add($control)|Out-Null
      return $row
    }

    Add-SettingsTitle 'Crimson Deploy Tool Einstellungen' 'Zentrale Optionen für Startverhalten, Deploy Schutz, Health Checks und lokale Config Backups auf deinem PC.'

    $behavior = New-Card 'Verhalten' 'Steuert, was die App beim Start und nach Deploys automatisch macht.'
    $cbOnline = New-SettingCheck 'Online Status beim Start automatisch prüfen' (Get-AppSettingBool 'autoHealthCheck' $true)
    $cbLog = New-SettingCheck 'Log beim Start eingeklappt lassen' (Get-AppSettingBool 'autoCollapseLog' $true)
    $cbHealthDeploy = New-SettingCheck 'Health Check nach Deploy ausführen' (Get-AppSettingBool 'autoHealthAfterDeploy' $true)
    $cbGlow = New-SettingCheck 'Premium Glow Effekte aktiviert' (Get-AppSettingBool 'premiumGlow' $true)
    $behavior.Children.Add($cbOnline)|Out-Null; $behavior.Children.Add($cbLog)|Out-Null; $behavior.Children.Add($cbHealthDeploy)|Out-Null; $behavior.Children.Add($cbGlow)|Out-Null

    $backupCard = New-Card 'Lokales Config Backup' 'Backups werden nur noch lokal auf deinem PC erstellt. Als Ziel kannst du auch einen OneDrive, Dropbox oder anderen Sync Ordner wählen.'
    $defaultBackupFolder = Get-ConfigBackupFolder ''
    $folderRow = [Windows.Controls.Grid]::new(); $folderRow.Margin = [Windows.Thickness]::new(0,0,0,10); $folderRow.ColumnDefinitions.Add([Windows.Controls.ColumnDefinition]::new()); $c=[Windows.Controls.ColumnDefinition]::new(); $c.Width=[Windows.GridLength]::new(118); $folderRow.ColumnDefinitions.Add($c)
    $tbFolder = New-InputBox $defaultBackupFolder 500; $tbFolder.HorizontalAlignment = 'Stretch'; [Windows.Controls.Grid]::SetColumn($tbFolder,0)
    $browse = [Windows.Controls.Button]::new(); $browse.Content = 'Ordner wählen'; $browse.Height=34; $browse.Margin=[Windows.Thickness]::new(8,0,0,0); $browse.Background=New-Brush '#0D1528'; $browse.Foreground=New-Brush '#22D3EE'; $browse.BorderBrush=New-Brush '#224F63'; [Windows.Controls.Grid]::SetColumn($browse,1)
    $folderRow.Children.Add($tbFolder)|Out-Null; $folderRow.Children.Add($browse)|Out-Null; $backupCard.Children.Add((New-SettingsRow 'Backup Ordner' $folderRow))|Out-Null
    $hint = [Windows.Controls.TextBlock]::new(); $hint.Text = 'MinIO wurde entfernt. Config Backups laufen wieder ausschließlich lokal.'; $hint.Foreground = New-Brush '#34D399'; $hint.FontSize = 11; $hint.Margin = [Windows.Thickness]::new(0,0,0,10); $backupCard.Children.Add($hint)|Out-Null
    $cbAutoBackup = New-SettingCheck 'Nach erfolgreichem Deploy automatisch lokales Config Backup erstellen' (Get-AppSettingBool 'autoConfigBackupAfterDeploy' $false)
    $backupCard.Children.Add($cbAutoBackup)|Out-Null
    $backupBtns = [Windows.Controls.StackPanel]::new(); $backupBtns.Orientation = 'Horizontal'; $backupBtns.Margin=[Windows.Thickness]::new(0,4,0,0)
    $btnNow = [Windows.Controls.Button]::new(); $btnNow.Content='Backup jetzt erstellen'; $btnNow.Width=170; $btnNow.Height=34; $btnNow.Background=New-Brush '#0891B2'; $btnNow.Foreground=New-Brush '#030C18'; $btnNow.BorderBrush=New-Brush '#22D3EE'; $btnNow.FontWeight=[Windows.FontWeights]::Bold; $btnNow.Margin=[Windows.Thickness]::new(0,0,8,0)
    $btnOpen = [Windows.Controls.Button]::new(); $btnOpen.Content='Ordner öffnen'; $btnOpen.Width=120; $btnOpen.Height=34; $btnOpen.Background=New-Brush '#0D1528'; $btnOpen.Foreground=New-Brush '#8FA3BE'; $btnOpen.BorderBrush=New-Brush '#183148'
    $backupBtns.Children.Add($btnNow)|Out-Null; $backupBtns.Children.Add($btnOpen)|Out-Null; $backupCard.Children.Add($backupBtns)|Out-Null

    $retention = New-Card 'Aufbewahrung' 'Begrenzt Verlauf und lokale Backup ZIPs, damit der Ordner sauber bleibt.'
    $row1=[Windows.Controls.StackPanel]::new(); $row1.Orientation='Horizontal'; $row1.Margin=[Windows.Thickness]::new(0,0,0,10)
    $lbl1=[Windows.Controls.TextBlock]::new(); $lbl1.Text='Deploy Verlauf behalten, Tage'; $lbl1.Foreground=New-Brush '#8FA3BE'; $lbl1.Width=230; $lbl1.VerticalAlignment='Center'
    $tbHistory=New-InputBox ([string](Get-AppSettingInt 'keepHistoryDays' 180 7)) 90
    $row1.Children.Add($lbl1)|Out-Null; $row1.Children.Add($tbHistory)|Out-Null
    $row2=[Windows.Controls.StackPanel]::new(); $row2.Orientation='Horizontal'
    $lbl2=[Windows.Controls.TextBlock]::new(); $lbl2.Text='Lokale Backup ZIPs behalten'; $lbl2.Foreground=New-Brush '#8FA3BE'; $lbl2.Width=230; $lbl2.VerticalAlignment='Center'
    $tbBackups=New-InputBox ([string](Get-AppSettingInt 'keepBackupCount' 10 1)) 90
    $row2.Children.Add($lbl2)|Out-Null; $row2.Children.Add($tbBackups)|Out-Null
    $retention.Children.Add($row1)|Out-Null; $retention.Children.Add($row2)|Out-Null

    $security = New-Card 'Sicherheit' 'Es werden keine MinIO Zugangsdaten mehr verwendet oder exportiert. Backups bleiben lokal auf deinem PC.'
    $sec = [Windows.Controls.TextBlock]::new(); $sec.Text='Support Pakete enthalten keine Private Key Inhalte. Lokale Config Backups enthalten deine App Einstellungen, weil sie zur Wiederherstellung gedacht sind.'; $sec.Foreground=New-Brush '#8FA3BE'; $sec.FontSize=11; $sec.TextWrapping='Wrap'
    $security.Children.Add($sec)|Out-Null

    $browse.Add_Click({
      $dlg = New-Object System.Windows.Forms.FolderBrowserDialog
      $dlg.Description = 'Lokalen Backup Ordner wählen'
      if (-not [string]::IsNullOrWhiteSpace($tbFolder.Text)) { $dlg.SelectedPath = $tbFolder.Text }
      if ($dlg.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) { $tbFolder.Text = $dlg.SelectedPath }
    })
    $btnNow.Add_Click({
      $folder = $tbFolder.Text
      if ([string]::IsNullOrWhiteSpace($folder)) { $folder = Get-ConfigBackupFolder '' }
      $script:AppSettings['backupFolder'] = $folder
      Save-AppSettings
      [void](New-ConfigBackupPackage $folder $false)
    })
    $btnOpen.Add_Click({
      $folder = $tbFolder.Text
      if ([string]::IsNullOrWhiteSpace($folder)) { $folder = Get-ConfigBackupFolder '' }
      if (-not [string]::IsNullOrWhiteSpace($folder)) { New-Item -ItemType Directory -Force -Path $folder | Out-Null; Start-Process explorer.exe $folder }
    })

    $buttons=[Windows.Controls.StackPanel]::new(); $buttons.Orientation='Horizontal'; $buttons.HorizontalAlignment='Right'; [Windows.Controls.Grid]::SetRow($buttons,1)
    $save=[Windows.Controls.Button]::new(); $save.Content='Speichern'; $save.Width=130; $save.Height=38; $save.Margin=[Windows.Thickness]::new(0,10,10,0); $save.Background=New-Brush '#0891B2'; $save.Foreground=New-Brush '#030C18'; $save.BorderBrush=New-Brush '#22D3EE'; $save.FontWeight=[Windows.FontWeights]::Bold
    $close=[Windows.Controls.Button]::new(); $close.Content='Schließen'; $close.Width=110; $close.Height=38; $close.Margin=[Windows.Thickness]::new(0,10,0,0); $close.Background=New-Brush '#0D1528'; $close.Foreground=New-Brush '#8FA3BE'; $close.BorderBrush=New-Brush '#183148'
    $buttons.Children.Add($save)|Out-Null; $buttons.Children.Add($close)|Out-Null; $outer.Children.Add($buttons)|Out-Null

    $save.Add_Click({
      $script:AppSettings['autoHealthCheck'] = [bool]$cbOnline.IsChecked
      $script:AppSettings['autoCollapseLog'] = [bool]$cbLog.IsChecked
      $script:AppSettings['autoHealthAfterDeploy'] = [bool]$cbHealthDeploy.IsChecked
      $script:AppSettings['premiumGlow'] = [bool]$cbGlow.IsChecked
      $script:AppSettings['autoConfigBackupAfterDeploy'] = [bool]$cbAutoBackup.IsChecked
      $script:AppSettings['backupFolder'] = [string]$tbFolder.Text
      $days = 180; [void][int]::TryParse($tbHistory.Text, [ref]$days); if ($days -lt 7) { $days = 7 }
      $keep = 10; [void][int]::TryParse($tbBackups.Text, [ref]$keep); if ($keep -lt 1) { $keep = 1 }
      $script:AppSettings['keepHistoryDays'] = $days
      $script:AppSettings['keepBackupCount'] = $keep
      Save-AppSettings
      if (-not [string]::IsNullOrWhiteSpace([string]$script:AppSettings['backupFolder'])) { Cleanup-ConfigBackupFolder ([string]$script:AppSettings['backupFolder']) }
      Add-UiLog 'Einstellungen gespeichert. Backup Ziel ist lokal.'
      $win.Close()
    })
    $close.Add_Click({ $win.Close() })
    $win.Content=$outer; [void]$win.ShowDialog()
  } catch { Add-UiLog ('FEHLER: Einstellungen konnten nicht geöffnet werden: ' + $_.Exception.Message) }
}

function New-RollbackCard($item, [string]$kind, [string]$currentVersion) {
  $zip = Get-ObjectPropertyString $item 'zip'
  $zv = Get-ObjectPropertyString $item 'zipVersion'
  if ([string]::IsNullOrWhiteSpace($zv)) { $zv = Version-FromFile $zip }
  $server = Get-ObjectPropertyString $item 'server'
  $ts = Get-ObjectPropertyString $item 'timestamp'
  $status = Get-ObjectPropertyString $item 'status'
  $backupPattern = if ($kind -eq 'hub') { "/opt/cr1ms0n-next-backup-$zv-*" } else { "/opt/crimson-acp-backup-$zv-*" }

  $card = [Windows.Controls.Border]::new()
  $card.Tag = $item
  $card.Margin = [Windows.Thickness]::new(0,0,0,10)
  $card.Padding = [Windows.Thickness]::new(14)
  $card.CornerRadius = [Windows.CornerRadius]::new(10)
  $card.Background = New-Brush '#0A1020'
  $card.BorderBrush = New-Brush '#183148'
  $card.BorderThickness = [Windows.Thickness]::new(1)
  $card.Cursor = [Windows.Input.Cursors]::Hand

  $stack = [Windows.Controls.StackPanel]::new()
  $top = [Windows.Controls.Grid]::new()
  $top.ColumnDefinitions.Add((New-Object Windows.Controls.ColumnDefinition -Property @{ Width = [Windows.GridLength]::new(1,[Windows.GridUnitType]::Star) })) | Out-Null
  $top.ColumnDefinitions.Add((New-Object Windows.Controls.ColumnDefinition -Property @{ Width = [Windows.GridLength]::new(120) })) | Out-Null
  $title = [Windows.Controls.TextBlock]::new(); $title.Text = "$server  $zv"; $title.Foreground = New-Brush '#DDE6F0'; $title.FontFamily = [Windows.Media.FontFamily]::new('Rajdhani, Segoe UI Semibold, Segoe UI'); $title.FontSize = 18; $title.FontWeight = [Windows.FontWeights]::Bold
  $badge = [Windows.Controls.TextBlock]::new(); $badge.Text = 'Backup möglich'; $badge.HorizontalAlignment='Right'; $badge.Foreground=New-Brush '#34D399'; $badge.FontFamily=[Windows.Media.FontFamily]::new('JetBrains Mono, Consolas'); $badge.FontSize=10; $badge.Padding=[Windows.Thickness]::new(8,3,8,3); $badge.Background=New-Brush '#1710B981'
  [Windows.Controls.Grid]::SetColumn($badge,1)
  $top.Children.Add($title)|Out-Null; $top.Children.Add($badge)|Out-Null
  $sub = [Windows.Controls.TextBlock]::new(); $sub.Text = "$zip"; $sub.Foreground=New-Brush '#22D3EE'; $sub.FontFamily=[Windows.Media.FontFamily]::new('JetBrains Mono, Consolas'); $sub.FontSize=11; $sub.Margin=[Windows.Thickness]::new(0,6,0,0); $sub.TextTrimming='CharacterEllipsis'
  $meta = [Windows.Controls.TextBlock]::new(); $meta.Text = "$status deployed am $ts`nRemote Backup Muster: $backupPattern`nAktuell gespeichert: $currentVersion"; $meta.Foreground=New-Brush '#8FA3BE'; $meta.FontSize=11; $meta.Margin=[Windows.Thickness]::new(0,8,0,0); $meta.TextWrapping='Wrap'
  $stack.Children.Add($top)|Out-Null; $stack.Children.Add($sub)|Out-Null; $stack.Children.Add($meta)|Out-Null
  $card.Child = $stack
  return $card
}

function Show-RollbackSelectionWindow() {
  try {
    if ($null -eq $script:SelectedServer) { Add-UiLog 'FEHLER: Kein Server gewählt.'; return }
    if ($script:IsRunning) { Add-UiLog 'FEHLER: Rollback nicht möglich, solange eine Aktion läuft.'; return }
    $kind = Get-ServerKind $script:SelectedServer
    $hostName = Get-ServerHost $script:SelectedServer
    $currentVersion = Get-LastServerVersion $script:SelectedServer
    $items = @(Get-HistoryItems | Where-Object {
      $action = Get-ObjectPropertyString $_ 'action'
      if ([string]::IsNullOrWhiteSpace($action)) { $action = 'Deploy' }
      (Get-ObjectPropertyString $_ 'status') -eq 'Success' -and $action -eq 'Deploy' -and ((Get-ObjectPropertyString $_ 'kind').ToLowerInvariant() -eq $kind -or (Get-ObjectPropertyString $_ 'host') -eq $hostName)
    } | Sort-Object { try { [datetime](Get-ObjectPropertyString $_ 'timestamp') } catch { [datetime]::MinValue } } -Descending | Select-Object -First 30)
    if ($items.Count -eq 0) {
      Add-UiLog 'Keine Rollback Einträge gefunden.'
      [System.Windows.MessageBox]::Show('Es wurden noch keine wiederherstellbaren Deployments gefunden.', 'Rollback', 'OK', 'Information') | Out-Null
      return
    }
    $win=[Windows.Window]::new(); $win.Title='Rollback auswählen'; $win.Width=820; $win.Height=640; $win.MinWidth=760; $win.MinHeight=560; $win.WindowStartupLocation='CenterOwner'; $win.Owner=$script:Window; $win.Background=New-Brush '#04070F'; Apply-CrimsonSubWindowStyle $win
    $outer=[Windows.Controls.Grid]::new(); $outer.Margin=[Windows.Thickness]::new(22)
    $outer.RowDefinitions.Add((New-Object Windows.Controls.RowDefinition -Property @{ Height=[Windows.GridLength]::Auto }))|Out-Null
    $outer.RowDefinitions.Add((New-Object Windows.Controls.RowDefinition -Property @{ Height=[Windows.GridLength]::new(1,[Windows.GridUnitType]::Star) }))|Out-Null
    $outer.RowDefinitions.Add((New-Object Windows.Controls.RowDefinition -Property @{ Height=[Windows.GridLength]::Auto }))|Out-Null
    $header=[Windows.Controls.StackPanel]::new(); $header.Margin=[Windows.Thickness]::new(0,0,0,16)
    $h=[Windows.Controls.TextBlock]::new(); $h.Text='Rollback Auswahl'; $h.Foreground=New-Brush '#DDE6F0'; $h.FontFamily=[Windows.Media.FontFamily]::new('Rajdhani, Segoe UI Semibold, Segoe UI'); $h.FontSize=24; $h.FontWeight=[Windows.FontWeights]::Bold
    $p=[Windows.Controls.TextBlock]::new(); $p.Text="Wähle ein erfolgreiches Deployment für $($script:SelectedServer.label). Neueste Einträge stehen oben."; $p.Foreground=New-Brush '#8FA3BE'; $p.FontSize=12
    $header.Children.Add($h)|Out-Null; $header.Children.Add($p)|Out-Null; $outer.Children.Add($header)|Out-Null
    $scroll=[Windows.Controls.ScrollViewer]::new(); $scroll.VerticalScrollBarVisibility='Auto'; $scroll.HorizontalScrollBarVisibility='Disabled'; [Windows.Controls.Grid]::SetRow($scroll,1)
    $list=[Windows.Controls.StackPanel]::new(); $scroll.Content=$list; $outer.Children.Add($scroll)|Out-Null
    $selectedCard = $null
    $selectCard = {
      param($card)
      if ($null -ne $script:RollbackSelectedCard) { $script:RollbackSelectedCard.BorderBrush = New-Brush '#183148'; $script:RollbackSelectedCard.Background = New-Brush '#0A1020'; $script:RollbackSelectedCard.Effect = $null }
      $script:RollbackSelectedCard = $card
      $card.BorderBrush = New-Brush '#8C22D3EE'; $card.Background = New-Brush '#111E36'; $card.Effect = New-Object Windows.Media.Effects.DropShadowEffect -Property @{ Color=[Windows.Media.ColorConverter]::ConvertFromString('#06B6D4'); BlurRadius=14; ShadowDepth=0; Opacity=0.28 }
    }
    foreach($item in $items){
      $card = New-RollbackCard $item $kind $currentVersion
      $card.Add_MouseLeftButtonUp({ & $selectCard $this })
      $list.Children.Add($card)|Out-Null
    }
    if($list.Children.Count -gt 0){ & $selectCard $list.Children[0] }
    $buttons=[Windows.Controls.StackPanel]::new(); $buttons.Orientation='Horizontal'; $buttons.HorizontalAlignment='Right'; $buttons.Margin=[Windows.Thickness]::new(0,16,0,0); [Windows.Controls.Grid]::SetRow($buttons,2)
    function New-RbButton([string]$text,[string]$bg,[string]$fg,[int]$w){ $b=[Windows.Controls.Button]::new(); $b.Content=$text; $b.Width=$w; $b.Height=38; $b.Margin=[Windows.Thickness]::new(0,0,10,0); $b.Background=New-Brush $bg; $b.Foreground=New-Brush $fg; $b.BorderBrush=New-Brush '#224F63'; $b.FontWeight=[Windows.FontWeights]::SemiBold; return $b }
    $start=New-RbButton 'Rollback starten' '#0891B2' '#030C18' 150
    $close=New-RbButton 'Abbrechen' '#0D1528' '#8FA3BE' 110
    $buttons.Children.Add($start)|Out-Null; $buttons.Children.Add($close)|Out-Null; $outer.Children.Add($buttons)|Out-Null
    $start.Add_Click({
      if($null -eq $script:RollbackSelectedCard){ return }
      $it=$script:RollbackSelectedCard.Tag
      $itZip=(Get-ObjectPropertyString $it 'zip')
      $itZipVersion=(Get-ObjectPropertyString $it 'zipVersion')
      $ver=if(-not [string]::IsNullOrWhiteSpace($itZipVersion)){$itZipVersion}else{Version-FromFile $itZip}
      if([string]::IsNullOrWhiteSpace($ver) -or $ver -eq 'manual'){ [System.Windows.MessageBox]::Show('Diese Rollback Version konnte nicht eindeutig erkannt werden.', 'Rollback', 'OK', 'Warning') | Out-Null; return }
      $msg="Du stellst $($script:SelectedServer.label) auf $ver zurück.`nAktuell gespeichert ist $currentVersion.`n`nFortfahren?"
      $res=[System.Windows.MessageBox]::Show($msg, 'Rollback bestätigen', 'YesNo', 'Warning')
      if($res -ne 'Yes'){ return }
      $script:CurrentRollbackVersion = $ver
      $script:CurrentZipName = $itZip
      $script:RollbackSuccessRecorded = $false
      $win.Close()
      Start-RemoteAction 'Rollback' (Build-RollbackScript $kind $ver)
    })
    $close.Add_Click({ $win.Close() })
    $win.Content=$outer; [void]$win.ShowDialog()
  } catch { Add-UiLog ('FEHLER: Rollback Auswahl konnte nicht geöffnet werden: ' + $_.Exception.Message) }
}

function Start-RemoteAction([string]$action, [string]$remoteScript) {
  if ($script:IsRunning) { return }
  if ($null -eq $script:SelectedServer) { Add-UiLog 'FEHLER: Kein Server gewählt.'; Set-Status 'Fehler' 'error'; return }
  $serverJson = $script:SelectedServer | ConvertTo-Json -Depth 10 -Compress
  $script:JobLogFile = Join-Path $script:LogDir ("crimson-$action-job-" + (Get-Date -Format 'yyyyMMdd-HHmmss') + '.log')
  [System.IO.File]::WriteAllText($script:JobLogFile, '', $script:Utf8NoBom)
  $script:LastJobLogCount = 0
  $script:CurrentAction = $action
  $script:CurrentStart = Get-Date
  if ($action -ne 'Rollback') { $script:CurrentZipName = '' }
  $script:CurrentServerLabel = Get-ServerLabel $script:SelectedServer
  $script:CurrentKind = Get-ServerKind $script:SelectedServer
  if ($action -ne 'Rollback') { $script:CurrentRollbackVersion = ''; $script:RollbackSuccessRecorded = $false }
  Set-ControlsRunning $true
  Set-Status ($action + ' läuft') 'running'
  Set-ProgressStage ($action + ' gestartet') 5
  Add-UiLog "$action gestartet: $($script:SelectedServer.label)"
  $root = $script:Root
  $script:DeployJob = Start-Job -ArgumentList $serverJson, $remoteScript, $script:JobLogFile, $root, $action -ScriptBlock {
    param($serverJson, $remoteScript, $jobLog, $root, $action)
    $ErrorActionPreference='Stop'
    $enc=[System.Text.UTF8Encoding]::new($false)
    function JobLog([string]$msg){ if($null -eq $msg){return}; $share=[System.IO.FileShare]::ReadWrite -bor [System.IO.FileShare]::Delete; $fs=[System.IO.File]::Open($jobLog,[System.IO.FileMode]::OpenOrCreate,[System.IO.FileAccess]::Write,$share); try{ [void]$fs.Seek(0,[System.IO.SeekOrigin]::End); $b=$enc.GetBytes(($msg -replace "`r",'')+[Environment]::NewLine); $fs.Write($b,0,$b.Length); $fs.Flush() } finally { $fs.Dispose() } }
    function Q([string]$s){ return '"' + ($s -replace '"','\"') + '"' }
    function ResolveKey([string]$path,[string]$root){ if([string]::IsNullOrWhiteSpace($path)){return ''}; if($path.StartsWith('~')){return $path.Replace('~',[Environment]::GetFolderPath('UserProfile'))}; if([IO.Path]::IsPathRooted($path)){return $path}; return Join-Path $root $path }
    function TestTcp([string]$hostName,[int]$port,[int]$timeoutMs){ JobLog "TCP Test startet: ${hostName}:${port}"; $client=New-Object System.Net.Sockets.TcpClient; try{$async=$client.BeginConnect($hostName,$port,$null,$null); if(-not $async.AsyncWaitHandle.WaitOne($timeoutMs,$false)){ try { $client.Close() } catch {}; JobLog "WARNUNG: TCP Test ohne Antwort nach $timeoutMs ms auf ${hostName}:${port}. SSH/SCP wird trotzdem versucht."; return $false }; $client.EndConnect($async); JobLog "TCP Test erfolgreich: ${hostName}:${port} erreichbar"; return $true} catch { JobLog ("WARNUNG: TCP Test fehlgeschlagen: " + $_.Exception.Message + ". SSH/SCP wird trotzdem versucht."); return $false } finally { try{$client.Close()}catch{} } }
    function InvokeProc([string]$file,[string[]]$arguments,[string]$stdinText,[int]$timeoutSeconds){ JobLog ("> " + $file + " " + (($arguments|ForEach-Object{Q $_}) -join ' ')); if($timeoutSeconds -gt 0){JobLog "Maximale Laufzeit: ${timeoutSeconds}s"}; $psi=New-Object System.Diagnostics.ProcessStartInfo; $psi.FileName=$file; $psi.Arguments=(($arguments|ForEach-Object{Q $_}) -join ' '); $psi.RedirectStandardOutput=$true; $psi.RedirectStandardError=$true; $psi.RedirectStandardInput=(-not [string]::IsNullOrEmpty($stdinText)); $psi.StandardOutputEncoding=$enc; $psi.StandardErrorEncoding=$enc; $psi.UseShellExecute=$false; $psi.CreateNoWindow=$true; $p=New-Object System.Diagnostics.Process; $p.StartInfo=$psi; [void]$p.Start(); $out=$p.StandardOutput.ReadToEndAsync(); $err=$p.StandardError.ReadToEndAsync(); if(-not [string]::IsNullOrEmpty($stdinText)){ $p.StandardInput.Write($stdinText); $p.StandardInput.Close() }; $start=Get-Date; $beat=Get-Date; while(-not $p.HasExited){ Start-Sleep -Milliseconds 350; $elapsed=[int]((Get-Date)-$start).TotalSeconds; if(((Get-Date)-$beat).TotalSeconds -ge 6){JobLog "$file läuft seit ${elapsed}s ..."; $beat=Get-Date}; if($timeoutSeconds -gt 0 -and $elapsed -ge $timeoutSeconds){try{$p.Kill()}catch{}; throw "$file Timeout nach ${timeoutSeconds}s. Prozess wurde beendet."}}; $p.WaitForExit(); $stdout=[string]$out.Result; $stderr=[string]$err.Result; if($stdout){ foreach($l in ($stdout -split "`r?`n")){ if($l){JobLog $l} } }; if($stderr){ foreach($l in ($stderr -split "`r?`n")){ if($l){JobLog ('STDERR: '+$l)} } }; if($p.ExitCode -ne 0){ throw "$file Exit Code: $($p.ExitCode)" } }
    $server=$serverJson|ConvertFrom-Json; $port=if($server.port){[int]$server.port}else{22}; $user=if($server.username){[string]$server.username}else{'root'}; $hostName=[string]$server.host; $key=ResolveKey ([string]$server.privateKeyPath) $root; if(-not(Test-Path -LiteralPath $key)){throw "Private Key nicht gefunden: $key"}; $remoteUserHost="${user}@${hostName}"
    try{ JobLog "$action Typ: $($server.kind)"; JobLog "TCP Vorprüfung startet"; $tcpOk = TestTcp $hostName $port 15000; if ($tcpOk) { JobLog "TCP Vorprüfung erfolgreich. SSH Aktion startet jetzt." } else { JobLog "WARNUNG: TCP Vorprüfung war nicht eindeutig. SSH Aktion startet trotzdem." }; InvokeProc 'ssh.exe' @('-T','-p',[string]$port,'-i',$key,'-o','BatchMode=yes','-o','PasswordAuthentication=no','-o','NumberOfPasswordPrompts=0','-o','ConnectTimeout=20','-o','ServerAliveInterval=20','-o','ServerAliveCountMax=3','-o','StrictHostKeyChecking=no','-o','LogLevel=ERROR',$remoteUserHost,'bash -s') $remoteScript 900; JobLog "$action Status: success" } catch { JobLog "$action Status: failed"; JobLog ('FEHLER DETAIL: '+$_.Exception.Message); throw }
  }
  $script:PollTimer.Start()
}

function Start-Preflight() {
  if ($script:IsRunning) { return }
  if ($null -eq $script:SelectedServer) { Add-UiLog 'FEHLER: Kein Server gewählt.'; Set-Status 'Fehler' 'error'; return }
  Set-Status 'Preflight läuft' 'running'
  Set-ProgressStage 'Check gestartet' 12
  $errors = 0
  $warnings = 0
  Add-UiLog 'Preflight Check startet.'
  if ([string]::IsNullOrWhiteSpace($script:SelectedZip)) { Add-UiLog 'WARNUNG: Keine ZIP gewählt. Remote Checks laufen trotzdem.'; $warnings++ }
  else {
    if (Test-Path -LiteralPath $script:SelectedZip) { Add-UiLog 'OK: ZIP existiert.' } else { Add-UiLog 'FEHLER: ZIP Datei existiert nicht.'; $errors++ }
    try { $fs=[IO.File]::Open($script:SelectedZip,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::ReadWrite); $fs.Dispose(); Add-UiLog 'OK: ZIP ist lesbar.' } catch { Add-UiLog ('FEHLER: ZIP ist nicht lesbar: ' + $_.Exception.Message); $errors++ }
    $expectedKind = Get-ServerKind $script:SelectedServer
    try {
      $zipKind = Validate-ZipPackage $script:SelectedZip $expectedKind
      Add-UiLog "OK: ZIP Typ erkannt: $zipKind"
      $version = Version-FromFile (Safe-FileName $script:SelectedZip)
      Add-UiLog "OK: ZIP Version erkannt: $version"
      $last = Get-LastServerVersion $script:SelectedServer
      if (-not [string]::IsNullOrWhiteSpace($last) -and $version -ne 'manual') {
        $cmp = Compare-CrimsonVersion $version $last
        if ($cmp -gt 0) { Add-UiLog "OK: Version ist neuer: $last -> $version" }
        elseif ($cmp -eq 0) { Add-UiLog "WARNUNG: Version ist identisch mit zuletzt gespeichert: $version"; $warnings++ }
        else { Add-UiLog "WARNUNG: Version ist älter als zuletzt gespeichert: $version < $last"; $warnings++ }
      }
    } catch { Add-UiLog ('FEHLER: ' + $_.Exception.Message); $errors++ }
  }
  foreach($cmdName in @('ssh.exe','scp.exe')) { try { $cmd=Get-Command $cmdName -ErrorAction SilentlyContinue; if($null -eq $cmd){ Add-UiLog "FEHLER: $cmdName wurde nicht gefunden."; $errors++ } else { Add-UiLog "OK: $cmdName gefunden: $($cmd.Source)" } } catch { Add-UiLog "FEHLER: $cmdName Prüfung fehlgeschlagen."; $errors++ } }
  $keyPath = Resolve-KeyPath (Get-ObjectPropertyString $script:SelectedServer 'privateKeyPath') $script:Root
  if ([string]::IsNullOrWhiteSpace($keyPath)) { Add-UiLog 'FEHLER: Private Key Pfad fehlt.'; $errors++ }
  elseif (Test-Path -LiteralPath $keyPath) { Add-UiLog 'OK: Private Key vorhanden.' }
  else { Add-UiLog "FEHLER: Private Key fehlt: $keyPath"; $errors++ }
  if ($errors -gt 0) { Set-Status 'Preflight Fehler' 'error'; Set-ProgressStage 'Check Fehler' 100; Add-UiLog "Preflight lokal abgebrochen: $errors Fehler, $warnings Warnungen."; return }
  Add-UiLog "Preflight lokal erfolgreich: $warnings Warnungen. Remote Checks starten."
  Start-RemoteAction 'Preflight' (Build-PreflightScript (Get-ServerKind $script:SelectedServer))
}

function Start-Rollback() {
  if ($null -eq $script:SelectedServer) { Add-UiLog 'FEHLER: Kein Server gewählt.'; return }
  Show-RollbackSelectionWindow
}

function Stop-CurrentJob() {
  if ($script:DeployJob -and $script:DeployJob.State -eq 'Running') {
    try { Stop-Job -Job $script:DeployJob -Force -ErrorAction SilentlyContinue } catch {}
    Add-UiLog 'Aktion wurde abgebrochen. Prüfe den Server bei laufendem SSH/SCP Prozess sicherheitshalber manuell.'
    Add-HistoryRecord $script:CurrentAction 'Abgebrochen' 'Manuell abgebrochen'
    Set-Status 'Abgebrochen' 'error'
    Set-ProgressStage 'Abgebrochen' 100
    Set-ControlsRunning $false
  }
}

function Read-UpdatePackageManifest([string]$path) {
  if ([string]::IsNullOrWhiteSpace($path)) { throw 'Kein Update Paket gewählt.' }
  if (-not (Test-Path -LiteralPath $path)) { throw "Update Paket nicht gefunden: $path" }
  if ([IO.Path]::GetExtension($path).ToLowerInvariant() -ne '.zip') { throw 'Update Paket muss eine ZIP Datei sein.' }
  $zip = $null
  try {
    $zip = [System.IO.Compression.ZipFile]::OpenRead($path)
    $manifestEntry = $zip.Entries | Where-Object { $_.FullName -eq 'update.json' } | Select-Object -First 1
    if ($null -eq $manifestEntry) { throw 'update.json fehlt im Update Paket.' }
    $hasApp = $false
    foreach ($entry in $zip.Entries) {
      $name = ($entry.FullName -replace '\\','/')
      if ($name.StartsWith('/') -or $name -match '^[A-Za-z]:/' -or $name -match '(^|/)\.\.(/|$)') { throw "Unsicherer Pfad im Update Paket: $name" }
      if ($name.StartsWith('app/') -and -not $name.EndsWith('/')) { $hasApp = $true }
    }
    if (-not $hasApp) { throw 'Der app/ Ordner fehlt im Update Paket.' }
    $reader = [System.IO.StreamReader]::new($manifestEntry.Open(), $script:Utf8NoBom, $true)
    try { $json = $reader.ReadToEnd() } finally { $reader.Dispose() }
    $manifest = $json | ConvertFrom-Json
    if ([string]::IsNullOrWhiteSpace([string]$manifest.version)) { throw 'update.json enthält keine version.' }
    if ([string]::IsNullOrWhiteSpace([string]$manifest.restart)) { throw 'update.json enthält keinen restart Eintrag.' }
    return $manifest
  } finally {
    if ($null -ne $zip) { $zip.Dispose() }
  }
}

function Test-SemanticVersionText([string]$version) {
  if ([string]::IsNullOrWhiteSpace($version)) { return $false }
  return ($version -match '^\d+\.\d+\.\d+(?:[-+][0-9A-Za-z._-]+)?$')
}

function Set-UpdatePackage([string]$path) {
  try {
    $manifest = Read-UpdatePackageManifest $path
    $manifestVersion = ([string]$manifest.version).Trim()
    if (-not (Test-SemanticVersionText $manifestVersion)) { throw "Update Version ist kein Semantic Versioning Wert: $manifestVersion" }
    $cmp = Compare-CrimsonVersion $manifestVersion $script:AppVersion
    $file = [IO.Path]::GetFileName($path)
    $status = 'gültig'
    $installable = $true
    if ($cmp -lt 0) { $status = 'älter als installiert'; $installable = $false }
    elseif ($cmp -eq 0) { $status = 'identisch mit installiert'; $installable = $false }
    $script:SelectedUpdatePackage = if ($installable) { $path } else { '' }
    $script:SelectedUpdateManifest = if ($installable) { $manifest } else { $null }
    $script:UpdateText.Text = "Aktuell: $script:AppVersion`nUpdate: $manifestVersion`nStatus: $status`nPaket: $file`nConfig, Logs und Backups bleiben erhalten."
    $script:InstallUpdateButton.IsEnabled = $installable
    Add-UiLog "Update Paket gewählt: $path"
    Add-UiLog "Update Vorschau: aktuell $script:AppVersion -> Paket $manifestVersion ($status)"
    if ($installable) {
      Set-Status 'Update bereit' 'success'
      Show-CrimsonToast 'Update Paket gültig' ("$script:AppVersion -> $manifestVersion") 'success'
    } else {
      Set-Status 'Update blockiert' 'error'
      Show-CrimsonToast 'Update blockiert' $status 'warn'
    }
  } catch {
    $script:SelectedUpdatePackage = ''
    $script:SelectedUpdateManifest = $null
    $script:InstallUpdateButton.IsEnabled = $false
    if ($script:UpdateText) { $script:UpdateText.Text = 'Update Paket ungültig oder nicht lesbar.' }
    Add-UiLog ('FEHLER: Update Paket ungültig: ' + $_.Exception.Message)
    Set-Status 'Update Fehler' 'error'
    Show-CrimsonToast 'Update Paket ungültig' $_.Exception.Message 'error'
  }
}

function Open-UpdateDialog() {
  $dlg = New-Object Microsoft.Win32.OpenFileDialog
  $dlg.Title = 'Crimson Update Paket wählen'
  $dlg.Filter = 'Crimson Update Pakete (*.zip)|*.zip|Alle Dateien (*.*)|*.*'
  $dlg.Multiselect = $false
  if ($dlg.ShowDialog($script:Window) -eq $true) { Set-UpdatePackage $dlg.FileName }
}

function Quote-ProcessArg([string]$arg) {
  if ($null -eq $arg) { return '""' }
  return '"' + ($arg -replace '"','\"') + '"'
}

function Install-UpdatePackage() {
  if ($script:IsRunning) { Add-UiLog 'FEHLER: Während eines Deploys kann kein App Update installiert werden.'; return }
  if ([string]::IsNullOrWhiteSpace($script:SelectedUpdatePackage)) { Add-UiLog 'FEHLER: Kein Update Paket gewählt.'; return }
  try { $manifestCheck = Read-UpdatePackageManifest $script:SelectedUpdatePackage; if ((Compare-CrimsonVersion ([string]$manifestCheck.version) $script:AppVersion) -le 0) { Add-UiLog 'FEHLER: Update Paket ist nicht neuer als die installierte Version.'; Show-CrimsonToast 'Update blockiert' 'Paket ist nicht neuer als installiert.' 'warn'; return } } catch { Add-UiLog ('FEHLER: Update Paket ungültig: ' + $_.Exception.Message); Show-CrimsonToast 'Update Fehler' $_.Exception.Message 'error'; return }
  $updater = Join-Path $script:Root 'Crimson Updater.exe'
  if (-not (Test-Path -LiteralPath $updater)) { Add-UiLog "FEHLER: Crimson Updater.exe fehlt: $updater"; Set-Status 'Updater fehlt' 'error'; return }
  Add-UiLog 'Update wird vorbereitet. Die App schließt sich gleich und startet danach neu.'; Show-CrimsonToast 'Update startet' 'Die App wird gleich geschlossen und vom Updater neu gestartet.' 'info'
  Set-Status 'Update läuft' 'running'
  $launcherPid = $env:CRIMSON_DEPLOYER_LAUNCHER_PID
  if ([string]::IsNullOrWhiteSpace($launcherPid)) { $launcherPid = '' }
  $args = @('--root', $script:Root, '--package', $script:SelectedUpdatePackage, '--main', 'Crimson Deploy Tool.exe', '--pid', [string]$launcherPid, '--pspid', [string]$PID)
  $psi = [System.Diagnostics.ProcessStartInfo]::new()
  $psi.FileName = $updater
  $psi.Arguments = (($args | ForEach-Object { Quote-ProcessArg ([string]$_) }) -join ' ')
  $psi.WorkingDirectory = $script:Root
  $psi.UseShellExecute = $false
  try {
    [System.Diagnostics.Process]::Start($psi) | Out-Null
    $script:Window.Dispatcher.BeginInvoke([Action]{
      try { $script:Window.Close() } catch {}
      try { [System.Windows.Application]::Current.Shutdown() } catch {}
    }) | Out-Null
  } catch {
    Add-UiLog ('FEHLER: Updater konnte nicht gestartet werden: ' + $_.Exception.Message)
    Set-Status 'Update Fehler' 'error'
  }
}

function Open-ZipDialog() {
  $dlg = New-Object Microsoft.Win32.OpenFileDialog
  $dlg.Title = 'Crimson Deploy ZIP wählen'
  $dlg.Filter = 'ZIP Dateien (*.zip)|*.zip|Alle Dateien (*.*)|*.*'
  $dlg.Multiselect = $false
  if ($dlg.ShowDialog($script:Window) -eq $true) { Set-ZipFile $dlg.FileName }
}

function Resolve-KeyPath([string]$path, [string]$root) {
  if ([string]::IsNullOrWhiteSpace($path)) { return '' }
  if ($path.StartsWith('~')) { return $path.Replace('~', [Environment]::GetFolderPath('UserProfile')) }
  if ([IO.Path]::IsPathRooted($path)) { return $path }
  return Join-Path $root $path
}

function Start-Deploy() {
  if ($script:IsRunning) { return }
  if ($null -eq $script:SelectedServer) { Add-UiLog 'FEHLER: Kein Server gewählt.'; Set-Status 'Fehler' 'error'; return }
  if ([string]::IsNullOrWhiteSpace($script:SelectedZip)) { Add-UiLog 'FEHLER: Keine ZIP gewählt.'; Set-Status 'Fehler' 'error'; return }

  $fileName = Safe-FileName $script:SelectedZip
  $serverKind = Get-ServerKind $script:SelectedServer
  try { $zipKind = Validate-ZipPackage $script:SelectedZip $serverKind }
  catch { Add-UiLog ('FEHLER: ' + $_.Exception.Message); Set-Status 'Fehler' 'error'; Set-ProgressStage 'ZIP Validierung fehlgeschlagen' 100; return }
  if (-not (Confirm-VersionDeployAllowed $fileName $script:SelectedServer)) { Add-UiLog 'Deploy wegen Versionswarnung abgebrochen.'; Set-Status 'Bereit' 'success'; return }

  $serverJson = $script:SelectedServer | ConvertTo-Json -Depth 10 -Compress
  $deployScript = Build-DeployScript $zipKind $fileName
  $script:JobLogFile = Join-Path $script:LogDir ('crimson-deploy-job-' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '.log')
  [System.IO.File]::WriteAllText($script:JobLogFile, '', $script:Utf8NoBom)
  $script:LastJobLogCount = 0
  $script:CurrentAction = 'Deploy'
  $script:CurrentStart = Get-Date
  $script:CurrentZipName = $fileName
  $script:CurrentServerLabel = Get-ServerLabel $script:SelectedServer
  $script:CurrentKind = $zipKind
  $script:DeploySuccessRecorded = $false
$script:StageHasError = $false
$script:AppIconSource = $null
$script:ToastTimer = $null
  Set-ControlsRunning $true
  Set-Status 'Deploy läuft' 'running'
  Set-ProgressStage 'Deploy gestartet' 12
  Add-UiLog "Deploy gestartet: $fileName"

  $root = $script:Root
  $zipPath = $script:SelectedZip
  $jobLog = $script:JobLogFile

  $script:DeployJob = Start-Job -ArgumentList $serverJson, $zipPath, $fileName, $deployScript, $jobLog, $root -ScriptBlock {
    param($serverJson, $zipPath, $fileName, $deployScript, $jobLog, $root)
    $ErrorActionPreference = 'Stop'
try {
  $script:Utf8NoBom = [System.Text.UTF8Encoding]::new($false)
  [Console]::OutputEncoding = $script:Utf8NoBom
  $OutputEncoding = $script:Utf8NoBom
} catch {}
    function JobLog([string]$msg) {
      if ($null -eq $msg) { return }
      $enc = [System.Text.UTF8Encoding]::new($false)
      $line = (($msg -replace "`r", '') + [Environment]::NewLine)
      $bytes = $enc.GetBytes($line)
      $dir = Split-Path -Parent $jobLog
      if (-not [string]::IsNullOrWhiteSpace($dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
      $fs = $null
      try {
        $share = [System.IO.FileShare]::ReadWrite -bor [System.IO.FileShare]::Delete
        $fs = [System.IO.File]::Open($jobLog, [System.IO.FileMode]::OpenOrCreate, [System.IO.FileAccess]::Write, $share)
        [void]$fs.Seek(0, [System.IO.SeekOrigin]::End)
        $fs.Write($bytes, 0, $bytes.Length)
        $fs.Flush()
      } finally {
        if ($null -ne $fs) { $fs.Dispose() }
      }
    }
    function Q([string]$s) { return '"' + ($s -replace '"','\"') + '"' }
    function Normalize-DeployKind($value) {
      try {
        foreach ($item in @($value)) {
          $text = ([string]$item).Trim().ToLowerInvariant()
          if ($text -eq 'hub') { return 'hub' }
          if ($text -eq 'acp') { return 'acp' }
        }
      } catch {}
      return ''
    }
    function ResolveKey([string]$path, [string]$root) {
      if ([string]::IsNullOrWhiteSpace($path)) { return '' }
      if ($path.StartsWith('~')) { return $path.Replace('~', [Environment]::GetFolderPath('UserProfile')) }
      if ([IO.Path]::IsPathRooted($path)) { return $path }
      return Join-Path $root $path
    }
    function RequireCommand([string]$name) {
      $cmd = Get-Command $name -ErrorAction SilentlyContinue
      if ($null -eq $cmd) { throw "$name wurde nicht gefunden. Bitte Windows OpenSSH Client installieren oder PATH prüfen." }
      JobLog "$name gefunden: $($cmd.Source)"
    }
    function InvokeProc([string]$file, [string[]]$arguments, [string]$stdinText, [int]$timeoutSeconds) {
      JobLog ("> " + $file + " " + (($arguments | ForEach-Object { Q $_ }) -join ' '))
      if ($timeoutSeconds -gt 0) { JobLog "Maximale Laufzeit: ${timeoutSeconds}s" }
      $psi = New-Object System.Diagnostics.ProcessStartInfo
      $psi.FileName = $file
      $psi.Arguments = (($arguments | ForEach-Object { Q $_ }) -join ' ')
      $psi.RedirectStandardOutput = $true
      $psi.RedirectStandardError = $true
      $psi.RedirectStandardInput = -not [string]::IsNullOrEmpty($stdinText)
      $psi.StandardOutputEncoding = [System.Text.UTF8Encoding]::new($false)
      $psi.StandardErrorEncoding = [System.Text.UTF8Encoding]::new($false)
      $psi.UseShellExecute = $false
      $psi.CreateNoWindow = $true
      $p = New-Object System.Diagnostics.Process
      $p.StartInfo = $psi
      [void]$p.Start()
      $stdoutTask = $p.StandardOutput.ReadToEndAsync()
      $stderrTask = $p.StandardError.ReadToEndAsync()
      if (-not [string]::IsNullOrEmpty($stdinText)) {
        $p.StandardInput.Write($stdinText)
        $p.StandardInput.Close()
      }
      $startTime = Get-Date
      $lastBeat = Get-Date
      while (-not $p.HasExited) {
        Start-Sleep -Milliseconds 350
        $elapsed = [int]((Get-Date) - $startTime).TotalSeconds
        if (((Get-Date) - $lastBeat).TotalSeconds -ge 6) {
          JobLog ("$file läuft seit ${elapsed}s ...")
          $lastBeat = Get-Date
        }
        if ($timeoutSeconds -gt 0 -and $elapsed -ge $timeoutSeconds) {
          try { $p.Kill() } catch {}
          try { $p.WaitForExit(3000) | Out-Null } catch {}
          throw "$file Timeout nach ${timeoutSeconds}s. Prozess wurde beendet."
        }
      }
      try { $p.WaitForExit(3000) | Out-Null } catch {}
      try { $stdoutTask.Wait(3000) | Out-Null } catch {}
      try { $stderrTask.Wait(3000) | Out-Null } catch {}
      $stdout = ''
      $stderr = ''
      try { $stdout = [string]$stdoutTask.Result } catch {}
      try { $stderr = [string]$stderrTask.Result } catch {}
      if (-not [string]::IsNullOrWhiteSpace($stdout)) {
        foreach ($line in ($stdout -split "`r?`n")) { if (-not [string]::IsNullOrWhiteSpace($line)) { JobLog $line } }
      }
      if (-not [string]::IsNullOrWhiteSpace($stderr)) {
        foreach ($line in ($stderr -split "`r?`n")) { if (-not [string]::IsNullOrWhiteSpace($line)) { JobLog ("STDERR: " + $line) } }
      }
      if ($p.ExitCode -ne 0) {
        if ([string]::IsNullOrWhiteSpace($stdout) -and [string]::IsNullOrWhiteSpace($stderr)) { JobLog "Keine Ausgabe von $file erhalten. Exit Code: $($p.ExitCode)" }
        throw "$file Exit Code: $($p.ExitCode)"
      }
    }
    function TestTcp([string]$hostName, [int]$port, [int]$timeoutMs) {
      JobLog "TCP Test startet: ${hostName}:${port}"
      $client = New-Object System.Net.Sockets.TcpClient
      try {
        $async = $client.BeginConnect($hostName, $port, $null, $null)
        if (-not $async.AsyncWaitHandle.WaitOne($timeoutMs, $false)) {
          try { $client.Close() } catch {}
          JobLog "WARNUNG: TCP Test ohne Antwort nach $timeoutMs ms auf ${hostName}:${port}. Deploy wird trotzdem über SCP/SSH versucht."
          return $false
        }
        $client.EndConnect($async)
        JobLog "TCP Test erfolgreich: ${hostName}:${port} erreichbar"
        return $true
      } catch {
        JobLog ("WARNUNG: TCP Test fehlgeschlagen: " + $_.Exception.Message + ". Deploy wird trotzdem über SCP/SSH versucht.")
        return $false
      } finally {
        try { $client.Close() } catch {}
      }
    }
    function InvokeScpUpload([string]$port, [string]$key, [string]$sourcePath, [string]$remotePath) {
      $baseArgs = @('-B', '-P', [string]$port, '-i', $key, '-o', 'BatchMode=yes', '-o', 'NumberOfPasswordPrompts=0', '-o', 'ConnectTimeout=10', '-o', 'ConnectionAttempts=1', '-o', 'ServerAliveInterval=10', '-o', 'ServerAliveCountMax=2', '-o', 'StrictHostKeyChecking=no', '-o', 'LogLevel=ERROR', $sourcePath, $remotePath)
      try {
        InvokeProc 'scp.exe' $baseArgs '' 600
        return
      } catch {
        JobLog ("SCP Standard Modus fehlgeschlagen: " + $_.Exception.Message)
        JobLog "Versuche SCP Legacy Modus mit -O, falls der Server SFTP nicht unterstützt."
        $legacyArgs = @('-O') + $baseArgs
        InvokeProc 'scp.exe' $legacyArgs '' 600
      }
    }

    $server = $serverJson | ConvertFrom-Json
    $serverKind = Normalize-DeployKind $server.kind
    if ([string]::IsNullOrWhiteSpace($serverKind)) { $serverKind = Normalize-DeployKind $server.type }
    if ([string]::IsNullOrWhiteSpace($serverKind)) { throw 'Server Typ fehlt oder ist ungültig. Erlaubt: hub oder acp.' }
    $port = if ($server.port) { [int]$server.port } else { 22 }
    $user = if ($server.username) { [string]$server.username } else { 'root' }
    $hostName = [string]$server.host
    $key = ResolveKey ([string]$server.privateKeyPath) $root
    if ([string]::IsNullOrWhiteSpace($key)) { throw 'Private Key fehlt. Diese WPF Version ist für SSH Key Deploy ausgelegt.' }
    if (-not (Test-Path -LiteralPath $key)) { throw "Private Key nicht gefunden: $key" }
    $remote = "${user}@${hostName}:/tmp/${fileName}"
    $remoteUserHost = "${user}@${hostName}"

    try {
      RequireCommand 'ssh.exe'
      RequireCommand 'scp.exe'
      JobLog "Deploy Typ: $serverKind"
      JobLog "Lokale ZIP: $zipPath"
      JobLog "Remote Ziel: $remote"
      JobLog "Private Key: $key"
      JobLog "TCP Vorprüfung startet"
      $tcpOk = TestTcp $hostName $port 15000
      if ($tcpOk) {
        JobLog 'TCP Vorprüfung erfolgreich. Direkter SCP Upload startet jetzt.'
      } else {
        JobLog 'WARNUNG: TCP Vorprüfung war nicht eindeutig. Direkter SCP Upload startet trotzdem.'
      }
      InvokeScpUpload ([string]$port) $key $zipPath $remote
      JobLog 'Upload abgeschlossen'
      InvokeProc 'ssh.exe' @('-T', '-p', [string]$port, '-i', $key, '-o', 'BatchMode=yes', '-o', 'PasswordAuthentication=no', '-o', 'NumberOfPasswordPrompts=0', '-o', 'ConnectTimeout=15', '-o', 'ServerAliveInterval=20', '-o', 'ServerAliveCountMax=3', '-o', 'StrictHostKeyChecking=no', '-o', 'LogLevel=ERROR', $remoteUserHost, 'bash -s') $deployScript 1800
      JobLog 'Deploy Status: success'
    } catch {
      JobLog 'Deploy Status: failed'
      JobLog ('FEHLER DETAIL: ' + $_.Exception.Message)
      if ($_.ScriptStackTrace) { JobLog $_.ScriptStackTrace }
      throw
    }
  }
  $script:PollTimer.Start()
}

$script:PollTimer = New-Object Windows.Threading.DispatcherTimer
$script:PollTimer.Interval = [TimeSpan]::FromMilliseconds(350)
$script:PollTimer.Add_Tick({
  try {
    if ($script:JobLogFile -and (Test-Path -LiteralPath $script:JobLogFile)) {
      $all = Read-SharedLines $script:JobLogFile
      if ($null -ne $all -and $all.Count -gt $script:LastJobLogCount) {
        for ($i = $script:LastJobLogCount; $i -lt $all.Count; $i++) {
          $jobLine = [string]$all[$i]
          Add-UiLog $jobLine
          if ($jobLine -match '(?i)^\s*Deploy Status:\s*success\s*$') { Register-DeploySuccess 'Job Log' }
          if ($jobLine -match '(?i)^\s*Rollback Status:\s*success\s*$') { Register-RollbackSuccess 'Job Log' }
        }
        $script:LastJobLogCount = $all.Count
      }
    }
    if ($script:DeployJob -and $script:DeployJob.State -ne 'Running') {
      $state = $script:DeployJob.State
      try {
        $received = Receive-Job -Job $script:DeployJob -ErrorAction Stop 2>&1
        foreach ($line in $received) { if ($line) { Add-UiLog ([string]$line) } }
      } catch {
        $m = $_.Exception.Message; if ([string]::IsNullOrWhiteSpace($m)) { $m = 'Hintergrundjob fehlgeschlagen. Details stehen direkt darüber im Log.' }; Add-UiLog ('FEHLER: ' + $m)
      }
      Remove-Job -Job $script:DeployJob -Force -ErrorAction SilentlyContinue
      $script:DeployJob = $null
      Set-ControlsRunning $false
      $script:PollTimer.Stop()
      if ($state -eq 'Completed') {
        Set-Status 'Erfolgreich' 'success'
        Set-ProgressStage 'Abgeschlossen' 100
        Add-UiLog ($script:CurrentAction + ' abgeschlossen.')
        if ($script:CurrentAction -eq 'Deploy') { Register-DeploySuccess 'Job Abschluss' } elseif ($script:CurrentAction -eq 'Rollback') { Register-RollbackSuccess 'Job Abschluss' } else { Add-HistoryRecord $script:CurrentAction 'Success' 'Abgeschlossen' }
        try { Refresh-ServerCardsAfterStateChange } catch {}
      } else {
        Set-Status 'Fehler' 'error'
        Set-ProgressStage 'Fehler' 100
        Add-UiLog ($script:CurrentAction + " beendet mit Status: $state")
        if ($script:CurrentAction -eq 'Rollback') { Add-RollbackHistoryRecord 'Failed' ("Job Status: $state") } else { Add-HistoryRecord $script:CurrentAction 'Failed' ("Job Status: $state") }; Show-CrimsonToast 'Aktion fehlgeschlagen' ("Status: $state") 'error'
      }
    }
  } catch {
    $pollMsg = $_.Exception.Message
    if ($pollMsg -notmatch '(?i)used by another process|von einem anderen Prozess verwendet|process cannot access the file') {
      Add-UiLog ('FEHLER Polling: ' + $pollMsg)
    }
  }
})

$script:PickZipButton.Add_Click({ Open-ZipDialog })
$script:PickUpdateButton.Add_Click({ Open-UpdateDialog })
$script:InstallUpdateButton.Add_Click({ Install-UpdatePackage })
$script:DeployButton.Add_Click({ Start-Deploy })
$script:CancelButton.Add_Click({ Stop-CurrentJob })
$script:PreflightButton.Add_Click({ Start-Preflight })
$script:RollbackButton.Add_Click({ Start-Rollback })
$script:HistoryButton.Add_Click({ Show-HistoryWindow })
$script:ExportLogsButton.Add_Click({ Create-SupportPackage })
$script:ServerManagerButton.Add_Click({ Show-ServerManagerWindow })
$script:RefreshServerStatusButton.Add_Click({ Start-ServerOnlineChecks })
$script:CloudBackupButton.Add_Click({ New-ConfigBackupPackage })
$script:RestoreBackupButton.Add_Click({ Restore-ConfigBackupPackage })
$script:SettingsButton.Add_Click({ Show-SettingsWindow })
$script:ToggleLogButton.Add_Click({
  if ($script:LogContainer.Visibility -eq [Windows.Visibility]::Visible) {
    $script:LogContainer.Visibility = [Windows.Visibility]::Collapsed
    $script:ToggleLogButton.Content = 'Log anzeigen'
  } else {
    $script:LogContainer.Visibility = [Windows.Visibility]::Visible
    $script:ToggleLogButton.Content = 'Log ausblenden'
    $script:LogBox.ScrollToEnd()
  }
})
$script:OpenLogsButton.Add_Click({
  if (Test-Path -LiteralPath $script:LogFile) { Start-Process explorer.exe -ArgumentList ('/select,"' + $script:LogFile + '"') }
})
$script:ClearLogsButton.Add_Click({
  $script:LogDocument.Blocks.Clear()
  Add-UiLog 'Livefeed geleert. Datei Log bleibt erhalten.'
})
$script:Window.Add_DragOver({
  if ($_.Data.GetDataPresent([Windows.DataFormats]::FileDrop)) { $_.Effects = [Windows.DragDropEffects]::Copy } else { $_.Effects = [Windows.DragDropEffects]::None }
  $_.Handled = $true
})
$script:Window.Add_Drop({
  $files = $_.Data.GetData([Windows.DataFormats]::FileDrop)
  if ($files -and $files.Length -gt 0) { Set-ZipFile ([string]$files[0]) }
  $_.Handled = $true
})
$script:DropZone.Add_MouseLeftButtonUp({ Open-ZipDialog })
$script:Window.Add_Closing({
  if ($script:DeployJob -and $script:DeployJob.State -eq 'Running') {
    try { Stop-Job -Job $script:DeployJob -Force -ErrorAction SilentlyContinue } catch {}
  }
})

Load-AppIcon
Load-Logo
if ($script:VersionText) { $script:VersionText.Text = $script:AppVersion }
$script:LogPathText.Text = 'Datei Log: ' + $script:LogFile
Add-UiLog ('Crimson Deploy Tool WPF ' + $script:AppVersion + ' gestartet.')
if (Test-Path -LiteralPath $script:UpdateResultFile) {
  try {
    $updateResult = Get-Content -LiteralPath $script:UpdateResultFile -Raw -Encoding UTF8
    if (-not [string]::IsNullOrWhiteSpace($updateResult)) {
      Add-UiLog $updateResult.Trim()
      if ($script:LastUpdateText) { $script:LastUpdateText.Text = ($updateResult -replace "`r?`n", ' · ').Trim() }
    }
    Remove-Item -LiteralPath $script:UpdateResultFile -Force -ErrorAction SilentlyContinue
  } catch {}
}
Add-UiLog 'Drag & Drop aktiv. ZIP direkt auf das Fenster ziehen.'
Load-AppSettings | Out-Null
Load-ServerHealthState
Load-Servers
Repair-DeployHistoryAndState
try { Refresh-ServerCardsAfterStateChange } catch {}
try { if ($script:AppSettings -and [bool]$script:AppSettings['autoHealthCheck']) { Start-ServerOnlineChecks } } catch {}
Set-Status 'Bereit' 'success'
Set-ProgressStage 'Bereit' 0

[void]$script:Window.ShowDialog()
