<#
.SYNOPSIS
  GUI-установщик скиллов Claude Cowork для ИСБ.

.DESCRIPTION
  Показывает модалку с чекбоксами ролей, при подтверждении скачивает install.ps1
  из main-ветки isb-cowork-bootstrap и запускает с выбранными ролями.

  Этот скрипт компилируется в isb-installer.exe через ps2exe (см. build.ps1).
#>

[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName PresentationCore
Add-Type -AssemblyName WindowsBase

[xml]$xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="ISB Cowork Installer"
        Width="540" Height="560"
        WindowStartupLocation="CenterScreen"
        ResizeMode="NoResize"
        FontFamily="Segoe UI"
        FontSize="13"
        Background="#FAFAFA">
  <Grid Margin="22">
    <Grid.RowDefinitions>
      <RowDefinition Height="Auto"/>
      <RowDefinition Height="Auto"/>
      <RowDefinition Height="Auto"/>
      <RowDefinition Height="*"/>
      <RowDefinition Height="Auto"/>
      <RowDefinition Height="Auto"/>
      <RowDefinition Height="Auto"/>
    </Grid.RowDefinitions>

    <TextBlock Grid.Row="0" Text="Установка AI-скиллов ИСБ"
               FontSize="20" FontWeight="SemiBold" Margin="0,0,0,4"/>
    <TextBlock Grid.Row="1" TextWrapping="Wrap" Foreground="#666" Margin="0,0,0,16"
               Text="Выберите роль(и) сотрудника. Скиллы установятся в ~/.claude/skills/ и будут автоматически обновляться при каждом запуске Claude Cowork."/>

    <TextBlock Grid.Row="2" Text="Роли:" FontWeight="SemiBold" Margin="0,0,0,8"/>

    <ScrollViewer Grid.Row="3" VerticalScrollBarVisibility="Auto" Margin="0,0,0,12">
      <StackPanel Name="RolesPanel">
        <CheckBox Name="cbOwner"    Content="Owner — владелец / руководитель (OWN-005, OWN-006)" Margin="0,4"/>
        <CheckBox Name="cbSales"    Content="Sales — отдел продаж" Margin="0,4"/>
        <CheckBox Name="cbService"  Content="Service — служба сервиса" Margin="0,4"/>
        <CheckBox Name="cbFinance"  Content="Finance — финансы / бухгалтерия" Margin="0,4"/>
        <CheckBox Name="cbHr"       Content="HR — кадры / Анастасия" Margin="0,4"/>
        <CheckBox Name="cbSupply"   Content="Supply — снабжение / Руфина" Margin="0,4"/>
        <CheckBox Name="cbInstall"  Content="Install — монтаж / инженеры" Margin="0,4"/>
        <CheckBox Name="cbDesign"   Content="Design — проектирование" Margin="0,4"/>
        <CheckBox Name="cbPlanning" Content="Planning — планирование / Темырлан" Margin="0,4"/>
        <Separator Margin="0,10"/>
        <CheckBox Name="cbDev"      Content="+ Dev-скиллы (методические + Vercel + Supabase)" Margin="0,4" FontWeight="SemiBold"/>
      </StackPanel>
    </ScrollViewer>

    <ProgressBar Grid.Row="4" Name="Progress" Height="6" Margin="0,0,0,8" IsIndeterminate="False" Visibility="Collapsed"/>
    <TextBlock   Grid.Row="5" Name="Status"   Foreground="#444" TextWrapping="Wrap" Margin="0,0,0,12" MinHeight="40"/>

    <StackPanel Grid.Row="6" Orientation="Horizontal" HorizontalAlignment="Right">
      <Button Name="BtnCancel"  Content="Отмена"      Width="100" Height="32" Margin="0,0,8,0"/>
      <Button Name="BtnInstall" Content="Установить"  Width="120" Height="32" IsDefault="True"
              Background="#2563EB" Foreground="White" FontWeight="SemiBold" BorderThickness="0"/>
    </StackPanel>
  </Grid>
</Window>
'@

$reader = New-Object System.Xml.XmlNodeReader $xaml
$window = [Windows.Markup.XamlReader]::Load($reader)

# Bind controls
$controls = @{}
foreach ($name in 'cbOwner','cbSales','cbService','cbFinance','cbHr','cbSupply','cbInstall','cbDesign','cbPlanning','cbDev','BtnInstall','BtnCancel','Status','Progress') {
  $controls[$name] = $window.FindName($name)
}

$roleMap = @{
  cbOwner    = 'owner'
  cbSales    = 'sales'
  cbService  = 'service'
  cbFinance  = 'finance'
  cbHr       = 'hr'
  cbSupply   = 'supply'
  cbInstall  = 'install'
  cbDesign   = 'design'
  cbPlanning = 'planning'
}

$controls['BtnCancel'].Add_Click({ $window.Close() })

$controls['BtnInstall'].Add_Click({
  $selectedRoles = @()
  foreach ($key in $roleMap.Keys) {
    if ($controls[$key].IsChecked) { $selectedRoles += $roleMap[$key] }
  }
  $includeDev = [bool]$controls['cbDev'].IsChecked

  if ($selectedRoles.Count -eq 0 -and -not $includeDev) {
    [System.Windows.MessageBox]::Show('Выберите хотя бы одну роль или Dev-скиллы.', 'ISB Installer', 'OK', 'Warning') | Out-Null
    return
  }

  # Disable controls during install
  $controls['BtnInstall'].IsEnabled = $false
  $controls['BtnCancel'].IsEnabled  = $false
  foreach ($key in $roleMap.Keys + 'cbDev') { $controls[$key].IsEnabled = $false }

  $controls['Progress'].Visibility = 'Visible'
  $controls['Progress'].IsIndeterminate = $true
  $controls['Status'].Text = 'Проверяю наличие Git…'
  $window.Dispatcher.Invoke([Action]{}, 'Render')

  try {
    # 1. Check Git
    $git = Get-Command git -ErrorAction SilentlyContinue
    if (-not $git) {
      throw "Git не найден. Установите Git for Windows (https://git-scm.com/download/win) и запустите установщик снова."
    }

    # 2. Download install.ps1
    $controls['Status'].Text = 'Скачиваю установщик…'
    $window.Dispatcher.Invoke([Action]{}, 'Render')

    $installPs1Url  = 'https://raw.githubusercontent.com/ISB-Engineering/isb-cowork-bootstrap/main/install.ps1'
    $installPs1Path = Join-Path $env:TEMP 'isb-install.ps1'
    Invoke-WebRequest -Uri $installPs1Url -OutFile $installPs1Path -UseBasicParsing

    # 3. Run install.ps1
    $rolesArg = if ($selectedRoles.Count -gt 0) { $selectedRoles -join ',' } else { 'owner' }
    # If user only selected Dev with no role — fall back to owner-as-shell + dev (owner is harmless, just base+2 ISB skills)
    if ($selectedRoles.Count -eq 0) { $rolesArg = 'owner' }

    $controls['Status'].Text = "Устанавливаю скиллы… (роли: $rolesArg$(if ($includeDev) { ' + dev' }))"
    $window.Dispatcher.Invoke([Action]{}, 'Render')

    $psArgs = @('-NoProfile','-ExecutionPolicy','Bypass','-File',$installPs1Path,'-Roles',$rolesArg)
    if ($includeDev) { $psArgs += '-IncludeDev' }

    $proc = Start-Process -FilePath 'powershell.exe' -ArgumentList $psArgs -NoNewWindow -PassThru -Wait `
            -RedirectStandardOutput (Join-Path $env:TEMP 'isb-install.log') `
            -RedirectStandardError  (Join-Path $env:TEMP 'isb-install-err.log')

    if ($proc.ExitCode -ne 0) {
      $errLog = Get-Content (Join-Path $env:TEMP 'isb-install-err.log') -Raw -ErrorAction SilentlyContinue
      throw "Ошибка установки (exit $($proc.ExitCode)). Лог: $env:TEMP\isb-install.log`n$errLog"
    }

    $controls['Progress'].IsIndeterminate = $false
    $controls['Progress'].Value = 100
    $controls['Status'].Text = "Готово! Скиллы установлены в $env:USERPROFILE\.claude\skills\. Запустите Claude Cowork — скиллы доступны автоматически. Они также будут обновляться при каждом запуске."

    [System.Windows.MessageBox]::Show("Установка завершена.`n`nРоли: $rolesArg$(if ($includeDev) { ' + dev' })`n`nЗапустите Claude Cowork — скиллы уже доступны.", 'ISB Installer', 'OK', 'Information') | Out-Null
    $window.Close()
  } catch {
    $controls['Progress'].IsIndeterminate = $false
    $controls['Progress'].Visibility = 'Collapsed'
    $controls['Status'].Text = "Ошибка: $($_.Exception.Message)"

    $controls['BtnInstall'].IsEnabled = $true
    $controls['BtnCancel'].IsEnabled  = $true
    foreach ($key in $roleMap.Keys + 'cbDev') { $controls[$key].IsEnabled = $true }

    [System.Windows.MessageBox]::Show($_.Exception.Message, 'Ошибка установки', 'OK', 'Error') | Out-Null
  }
})

# Show window
$window.ShowDialog() | Out-Null
