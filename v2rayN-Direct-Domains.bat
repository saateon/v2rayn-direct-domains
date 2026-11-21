@echo off
title v2rayN Direct Domains
net session >nul 2>&1 || (
  powershell -NoProfile -Command "Start-Process -Verb RunAs -FilePath '%~f0'"
  exit /b
)
start "" powershell -NoProfile -STA -WindowStyle Hidden -ExecutionPolicy Bypass -Command "$env:D4_BAT='%~f0'; $f='%~f0'; try { $s=[IO.File]::ReadAllText($f,[Text.Encoding]::UTF8); iex $s.Substring($s.LastIndexOf('#PS_START')+9) } catch { Add-Type -AssemblyName PresentationFramework; [void][Windows.MessageBox]::Show($_.Exception.Message,'v2rayN Direct Domains') }"
exit /b

#PS_START

$ErrorActionPreference = 'Stop'
$SelfTest = $env:SSH2V_SELFTEST
Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Windows.Forms
$LogFile   = Join-Path $env:TEMP 'ssh2v2rayn.log'
$Utf8NoBom = New-Object System.Text.UTF8Encoding $false
function Write-Log([string]$m) { try { Add-Content -LiteralPath $LogFile -Value ("[{0:yyyy-MM-dd HH:mm:ss}] {1}" -f (Get-Date), $m) -Encoding UTF8 } catch {} }

# =====================================================================
#  SQLite (uses v2rayN's own e_sqlite3.dll - no external dependency)
# =====================================================================
if (-not ('Ssh2V.Sqlite' -as [type])) {
Add-Type -TypeDefinition @'
using System; using System.Collections.Generic; using System.Runtime.InteropServices; using System.Text;
namespace Ssh2V {
public static class Sqlite {
  [DllImport("kernel32", SetLastError=true, CharSet=CharSet.Unicode)] static extern IntPtr LoadLibrary(string p);
  const string L = "e_sqlite3"; const CallingConvention C = CallingConvention.Cdecl;
  [DllImport(L, CallingConvention=C)] static extern int sqlite3_open_v2(byte[] f, out IntPtr db, int flags, IntPtr vfs);
  [DllImport(L, CallingConvention=C)] static extern int sqlite3_close_v2(IntPtr db);
  [DllImport(L, CallingConvention=C)] static extern int sqlite3_busy_timeout(IntPtr db, int ms);
  [DllImport(L, CallingConvention=C)] static extern int sqlite3_prepare_v2(IntPtr db, byte[] sql, int n, out IntPtr st, IntPtr tail);
  [DllImport(L, CallingConvention=C)] static extern int sqlite3_step(IntPtr st);
  [DllImport(L, CallingConvention=C)] static extern int sqlite3_finalize(IntPtr st);
  [DllImport(L, CallingConvention=C)] static extern int sqlite3_column_count(IntPtr st);
  [DllImport(L, CallingConvention=C)] static extern IntPtr sqlite3_column_name(IntPtr st, int i);
  [DllImport(L, CallingConvention=C)] static extern int sqlite3_column_type(IntPtr st, int i);
  [DllImport(L, CallingConvention=C)] static extern long sqlite3_column_int64(IntPtr st, int i);
  [DllImport(L, CallingConvention=C)] static extern IntPtr sqlite3_column_text(IntPtr st, int i);
  [DllImport(L, CallingConvention=C)] static extern int sqlite3_column_bytes(IntPtr st, int i);
  [DllImport(L, CallingConvention=C)] static extern int sqlite3_bind_text(IntPtr st, int i, byte[] v, int n, IntPtr d);
  [DllImport(L, CallingConvention=C)] static extern int sqlite3_bind_int64(IntPtr st, int i, long v);
  [DllImport(L, CallingConvention=C)] static extern int sqlite3_bind_null(IntPtr st, int i);
  [DllImport(L, CallingConvention=C)] static extern IntPtr sqlite3_errmsg(IntPtr db);
  public static void Load(string path) {
    if (LoadLibrary(path) == IntPtr.Zero) throw new Exception("Cannot load " + path + " (error " + Marshal.GetLastWin32Error() + ")");
  }
  static byte[] U(string s) { return Encoding.UTF8.GetBytes(s + "\0"); }
  static string S(IntPtr p, int n) { if (p == IntPtr.Zero) return null; byte[] b = new byte[n]; Marshal.Copy(p, b, 0, n); return Encoding.UTF8.GetString(b); }
  static string Z(IntPtr p) { if (p == IntPtr.Zero) return null; int n = 0; while (Marshal.ReadByte(p, n) != 0) n++; return S(p, n); }
  public static IntPtr Open(string file) {
    IntPtr db; int rc = sqlite3_open_v2(U(file), out db, 0x02, IntPtr.Zero);
    if (rc != 0) throw new Exception("Cannot open database (rc=" + rc + ")");
    sqlite3_busy_timeout(db, 8000); return db;
  }
  public static void Close(IntPtr db) { if (db != IntPtr.Zero) sqlite3_close_v2(db); }
  public static List<Dictionary<string, object>> Query(IntPtr db, string sql, object[] args) {
    IntPtr st;
    if (sqlite3_prepare_v2(db, U(sql), -1, out st, IntPtr.Zero) != 0) throw new Exception(Z(sqlite3_errmsg(db)));
    var rows = new List<Dictionary<string, object>>();
    try {
      if (args != null) for (int i = 0; i < args.Length; i++) {
        object a = args[i];
        if (a == null) sqlite3_bind_null(st, i + 1);
        else if (a is int || a is long || a is short) sqlite3_bind_int64(st, i + 1, Convert.ToInt64(a));
        else if (a is bool) sqlite3_bind_int64(st, i + 1, ((bool)a) ? 1 : 0);
        else { byte[] b = Encoding.UTF8.GetBytes(a.ToString()); sqlite3_bind_text(st, i + 1, b, b.Length, new IntPtr(-1)); }
      }
      while (true) {
        int rc = sqlite3_step(st);
        if (rc == 101) break;
        if (rc != 100) throw new Exception(Z(sqlite3_errmsg(db)));
        var r = new Dictionary<string, object>(StringComparer.OrdinalIgnoreCase);
        int n = sqlite3_column_count(st);
        for (int i = 0; i < n; i++) {
          string name = Z(sqlite3_column_name(st, i)); int t = sqlite3_column_type(st, i);
          if (t == 1) r[name] = sqlite3_column_int64(st, i);
          else if (t == 5) r[name] = null;
          else { IntPtr p = sqlite3_column_text(st, i); r[name] = S(p, sqlite3_column_bytes(st, i)); }
        }
        rows.Add(r);
      }
    } finally { sqlite3_finalize(st); }
    return rows;
  }
}}
'@
}

# =====================================================================
#  v2rayN discovery
# =====================================================================
function Find-V2rayN([switch]$Quick) {
  $seen = @{}; $list = New-Object System.Collections.ArrayList
  $add = {
    param($exe)
    $key = $exe.ToLower(); if ($seen.ContainsKey($key)) { return }; $seen[$key] = 1
    $root = Split-Path $exe
    [void]$list.Add([pscustomobject]@{
      Exe = $exe; Root = $root
      Version = [string](Get-Item -LiteralPath $exe).VersionInfo.FileVersion
      HasDb = (Test-Path -LiteralPath (Join-Path $root 'guiConfigs\guiNDB.db'))
    })
  }
  $roots = @('C:\app')
  if (-not $Quick) {
    $roots += @('C:\v2rayN', $env:ProgramFiles, ${env:ProgramFiles(x86)}, $env:LOCALAPPDATA, $env:APPDATA,
                "$env:USERPROFILE\Desktop", "$env:USERPROFILE\Downloads", "$env:USERPROFILE\Documents")
    $skip = 'Windows', '$Recycle.Bin', 'System Volume Information', 'ProgramData', 'Program Files', 'Program Files (x86)', 'Users', 'Recovery', 'PerfLogs'
    foreach ($d in [IO.DriveInfo]::GetDrives()) {
      if ($d.DriveType -ne 'Fixed' -or -not $d.IsReady) { continue }
      Get-ChildItem -LiteralPath $d.RootDirectory.FullName -Directory -Force -ErrorAction SilentlyContinue |
        Where-Object { $skip -notcontains $_.Name } | ForEach-Object { $roots += $_.FullName }
    }
  }
  foreach ($r in $roots) {
    if ($r -and (Test-Path -LiteralPath $r)) {
      Get-ChildItem -LiteralPath $r -Recurse -Depth 3 -Filter 'v2rayN.exe' -File -ErrorAction SilentlyContinue |
        ForEach-Object { & $add $_.FullName }
    }
  }
  $list | Sort-Object @{ e = { $_.HasDb }; Descending = $true }, @{ e = { try { [version]$_.Version } catch { [version]'0.0' } }; Descending = $true }
}

function Find-SqliteDll([string]$root) {
  $direct = Join-Path $root 'e_sqlite3.dll'
  if (Test-Path -LiteralPath $direct) { return $direct }
  $arch = if ($env:PROCESSOR_ARCHITECTURE -eq 'ARM64') { 'win-arm64' } elseif ([Environment]::Is64BitProcess) { 'win-x64' } else { 'win-x86' }
  $all = @(Get-ChildItem -LiteralPath $root -Recurse -Depth 4 -Filter 'e_sqlite3.dll' -File -ErrorAction SilentlyContinue)
  $pick = $all | Where-Object { $_.FullName -match [regex]::Escape($arch) } | Select-Object -First 1
  if (-not $pick) { $pick = $all | Select-Object -First 1 }
  if ($pick) { return $pick.FullName }
  return $null
}

function Find-SingBox([string]$root) {
  $p = Join-Path $root 'bin\sing_box\sing-box.exe'
  if (Test-Path -LiteralPath $p) { return $p }
  $f = Get-ChildItem -LiteralPath (Join-Path $root 'bin') -Recurse -Depth 3 -Filter 'sing-box.exe' -File -ErrorAction SilentlyContinue | Select-Object -First 1
  if ($f) { return $f.FullName }
  return $null
}

function Use-Install($inst) {
  $dll = Find-SqliteDll $inst.Root
  if (-not $dll) { throw "e_sqlite3.dll در پوشه v2rayN پیدا نشد." }
  if (-not $script:SqliteLoaded) { [Ssh2V.Sqlite]::Load($dll); $script:SqliteLoaded = $dll }
  $script:V       = $inst
  $script:CfgDir  = Join-Path $inst.Root 'guiConfigs'
  $script:DbPath  = Join-Path $script:CfgDir 'guiNDB.db'
  $script:SingBox = Find-SingBox $inst.Root
  Write-Log "Using v2rayN at $($inst.Root) (v$($inst.Version))"
}

# =====================================================================
#  Database helpers
# =====================================================================
function Use-Db([scriptblock]$body) {
  $db = [Ssh2V.Sqlite]::Open($script:DbPath)
  try { & $body $db } finally { [Ssh2V.Sqlite]::Close($db) }
}
function Q($db, [string]$sql, $params) { [Ssh2V.Sqlite]::Query($db, $sql, [object[]]$params) }

function Backup-Db {
  $dir = Join-Path $script:CfgDir 'ssh-tool-backups'
  New-Item -ItemType Directory -Force -Path $dir | Out-Null
  Copy-Item -LiteralPath $script:DbPath -Destination (Join-Path $dir ("guiNDB-{0:yyyyMMdd-HHmmss}.db" -f (Get-Date))) -Force
  Get-ChildItem -LiteralPath $dir -Filter 'guiNDB-*.db' | Sort-Object LastWriteTime -Descending | Select-Object -Skip 10 | Remove-Item -Force
}

function Get-SshEntries {
  $rows = @(Use-Db { param($db) Q $db 'select IndexId, Remarks, Address, PreSocksPort from ProfileItem where ConfigType = 2' $null })
  foreach ($r in $rows) {
    if (-not $r['Address']) { continue }
    $path = Join-Path $script:CfgDir ([string]$r['Address'])
    if (-not (Test-Path -LiteralPath $path)) { continue }
    try { $j = [IO.File]::ReadAllText($path, [Text.Encoding]::UTF8) | ConvertFrom-Json } catch { continue }
    $ob = @($j.outbounds) | Where-Object { $_.type -eq 'ssh' } | Select-Object -First 1
    if (-not $ob) { continue }
    [pscustomobject]@{
      Id = [string]$r['IndexId']; Name = [string]$r['Remarks']; File = $path
      Server = [string]$ob.server; Port = [string]$ob.server_port; User = [string]$ob.user; Socks = $r['PreSocksPort']
      Detail = ('{0}@{1}:{2}    SOCKS {3}' -f $ob.user, $ob.server, $ob.server_port, $r['PreSocksPort'])
    }
  }
}

function Get-FreeSocksPort {
  $used = @{}
  foreach ($r in @(Use-Db { param($db) Q $db 'select PreSocksPort as p from ProfileItem where PreSocksPort is not null' $null })) {
    if ($r['p']) { $used[[int]$r['p']] = 1 }
  }
  try { [Net.NetworkInformation.IPGlobalProperties]::GetIPGlobalProperties().GetActiveTcpListeners() | ForEach-Object { $used[$_.Port] = 1 } } catch {}
  $p = 10900; while ($used.ContainsKey($p)) { $p++ }; return $p
}

function Get-Tag([string]$name) {
  $t = ($name -replace '[^\w\-\.]', '_').Trim('_'); if (-not $t) { $t = 'ssh' }; return $t
}

function New-SingBoxJson($o, [int]$listen) {
  $ob = [ordered]@{ type = 'ssh'; tag = (Get-Tag $o.Name); server = $o.Server; server_port = [int]$o.Port; user = $o.User }
  if ($o.KeyPath) { $ob.private_key_path = $o.KeyPath; if ($o.Password) { $ob.private_key_passphrase = $o.Password } }
  else { $ob.password = $o.Password }
  $cfg = [ordered]@{
    log       = [ordered]@{ level = 'warn' }
    inbounds  = @([ordered]@{ type = 'mixed'; tag = 'socks-in'; listen = '127.0.0.1'; listen_port = $listen })
    outbounds = @($ob, [ordered]@{ type = 'direct'; tag = 'direct' })
    route     = [ordered]@{ final = $ob.tag }
  }
  $cfg | ConvertTo-Json -Depth 8
}

function Add-SshEntry($o) {
  $file  = [guid]::NewGuid().ToString() + '.json'
  $socks = Get-FreeSocksPort
  $id    = [string](Get-Random -Minimum ([long]4000000000000000000) -Maximum ([long]4999999999999999999))
  [IO.File]::WriteAllText((Join-Path $script:CfgDir $file), (New-SingBoxJson $o $socks), $Utf8NoBom)
  try {
    Use-Db {
      param($db)
      $cols = @(Q $db 'pragma table_info(ProfileItem)' $null)
      $ver = $null
      if ($cols | Where-Object { $_['name'] -ieq 'ConfigVersion' }) {
        $v = @(Q $db 'select max(ConfigVersion) as v from ProfileItem' $null)
        if ($v.Count -and $v[0]['v']) { $ver = [int]$v[0]['v'] }
        elseif ($script:V.Version -like '6.*') { $ver = 2 } else { $ver = 4 }
      }
      $vals = [ordered]@{}
      foreach ($c in $cols) {
        $n = [string]$c['name']; $vals[$n] = $null
        if ([int64]$c['notnull'] -eq 1 -and $null -eq $c['dflt_value'] -and [int64]$c['pk'] -eq 0) {
          if ([string]$c['type'] -match 'INT|REAL|NUM') { $vals[$n] = 0 } else { $vals[$n] = '' }
        }
      }
      $set = @{ IndexId = $id; ConfigType = 2; CoreType = 24; Remarks = $o.Name; Address = $file; Port = 0
                PreSocksPort = $socks; DisplayLog = 1; IsSub = 0; AlterId = 0; ConfigVersion = $ver }
      foreach ($k in @($set.Keys)) {
        $match = @($vals.Keys) | Where-Object { $_ -ieq $k } | Select-Object -First 1
        if ($match -and $null -ne $set[$k]) { $vals[$match] = $set[$k] }
      }
      $names = (@($vals.Keys) | ForEach-Object { '"' + $_ + '"' }) -join ','
      $ph = (@('?') * $vals.Count) -join ','
      Q $db "insert into ProfileItem ($names) values ($ph)" (@($vals.Values)) | Out-Null
    }
  } catch {
    Remove-Item -LiteralPath (Join-Path $script:CfgDir $file) -Force -ErrorAction SilentlyContinue
    throw
  }
  Write-Log "Added SSH entry '$($o.Name)' -> $($o.Server):$($o.Port) socks $socks"
  return $socks
}

function Remove-SshEntry($e) {
  Use-Db {
    param($db)
    Q $db 'delete from ProfileItem where IndexId = ?' @($e.Id) | Out-Null
    try { Q $db 'delete from ProfileExItem where IndexId = ?' @($e.Id) | Out-Null } catch {}
  }
  Remove-Item -LiteralPath $e.File -Force -ErrorAction SilentlyContinue
  Write-Log "Removed SSH entry '$($e.Name)'"
}

function Restart-V2rayN {
  $root = $script:V.Root
  Get-Process -ErrorAction SilentlyContinue | Where-Object {
    try { $_.Path -and $_.Path.StartsWith($root, [StringComparison]::OrdinalIgnoreCase) } catch { $false }
  } | Stop-Process -Force -ErrorAction SilentlyContinue
  Start-Sleep -Milliseconds 900
  Start-Process -FilePath $script:V.Exe -WorkingDirectory $root
  Write-Log 'Restarted v2rayN'
}


$script:SharedXaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="SSH → v2rayN" Width="780" Height="790" MinWidth="700" MinHeight="660"
        WindowStartupLocation="CenterScreen" FlowDirection="RightToLeft"
        FontFamily="Segoe UI" FontSize="13" Foreground="{{TEXT}}" Background="{{BG}}"
        UseLayoutRounding="True" SnapsToDevicePixels="True" TextOptions.TextFormattingMode="Display">
  <Window.Resources>
    <SolidColorBrush x:Key="Surface"   Color="{{SURFACE}}"/>
    <SolidColorBrush x:Key="Surface2"  Color="{{SURFACE2}}"/>
    <SolidColorBrush x:Key="Field"     Color="{{FIELD}}"/>
    <SolidColorBrush x:Key="Line"      Color="{{LINE}}"/>
    <SolidColorBrush x:Key="LineHover" Color="{{LINEHOVER}}"/>
    <SolidColorBrush x:Key="Text"      Color="{{TEXT}}"/>
    <SolidColorBrush x:Key="Muted"     Color="{{MUTED}}"/>
    <SolidColorBrush x:Key="Accent"    Color="{{ACCENT}}"/>
    <SolidColorBrush x:Key="AccentText" Color="{{ACCENTTEXT}}"/>
    <SolidColorBrush x:Key="Ok"        Color="{{OK}}"/>
    <SolidColorBrush x:Key="Err"       Color="{{ERR}}"/>

    <Style x:Key="Card" TargetType="Border">
      <Setter Property="Background" Value="{StaticResource Surface}"/>
      <Setter Property="BorderBrush" Value="{StaticResource Line}"/>
      <Setter Property="BorderThickness" Value="1"/>
      <Setter Property="CornerRadius" Value="12"/>
      <Setter Property="Padding" Value="22,20"/>
    </Style>
    <Style x:Key="H2" TargetType="TextBlock">
      <Setter Property="FontSize" Value="15"/><Setter Property="FontWeight" Value="SemiBold"/>
    </Style>
    <Style x:Key="Hint" TargetType="TextBlock">
      <Setter Property="Foreground" Value="{StaticResource Muted}"/><Setter Property="FontSize" Value="12"/>
    </Style>
    <Style x:Key="Label" TargetType="TextBlock">
      <Setter Property="Foreground" Value="{StaticResource Muted}"/><Setter Property="FontSize" Value="12"/>
      <Setter Property="Margin" Value="0,0,0,6"/>
    </Style>

    <Style TargetType="TextBox">
      <Setter Property="Background" Value="{StaticResource Field}"/>
      <Setter Property="Foreground" Value="{StaticResource Text}"/>
      <Setter Property="BorderBrush" Value="{StaticResource Line}"/>
      <Setter Property="BorderThickness" Value="1"/>
      <Setter Property="Padding" Value="10,7"/>
      <Setter Property="VerticalContentAlignment" Value="Center"/>
      <Setter Property="CaretBrush" Value="{StaticResource Text}"/>
      <Setter Property="SelectionBrush" Value="{StaticResource Accent}"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="TextBox">
            <Border x:Name="b" Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}"
                    BorderThickness="{TemplateBinding BorderThickness}" CornerRadius="8">
              <ScrollViewer x:Name="PART_ContentHost" Margin="{TemplateBinding Padding}" VerticalAlignment="{TemplateBinding VerticalContentAlignment}"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="b" Property="BorderBrush" Value="{StaticResource LineHover}"/></Trigger>
              <Trigger Property="IsKeyboardFocused" Value="True"><Setter TargetName="b" Property="BorderBrush" Value="{StaticResource Accent}"/></Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style TargetType="PasswordBox">
      <Setter Property="Background" Value="{StaticResource Field}"/>
      <Setter Property="Foreground" Value="{StaticResource Text}"/>
      <Setter Property="BorderBrush" Value="{StaticResource Line}"/>
      <Setter Property="BorderThickness" Value="1"/>
      <Setter Property="Padding" Value="10,7"/>
      <Setter Property="CaretBrush" Value="{StaticResource Text}"/>
      <Setter Property="SelectionBrush" Value="{StaticResource Accent}"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="PasswordBox">
            <Border x:Name="b" Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}"
                    BorderThickness="{TemplateBinding BorderThickness}" CornerRadius="8">
              <ScrollViewer x:Name="PART_ContentHost" Margin="{TemplateBinding Padding}" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="b" Property="BorderBrush" Value="{StaticResource LineHover}"/></Trigger>
              <Trigger Property="IsKeyboardFocused" Value="True"><Setter TargetName="b" Property="BorderBrush" Value="{StaticResource Accent}"/></Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <Style x:Key="BtnBase" TargetType="Button">
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Padding" Value="16,8"/>
      <Setter Property="FontWeight" Value="SemiBold"/>
      <Setter Property="BorderThickness" Value="1"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="b" Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}"
                    BorderThickness="{TemplateBinding BorderThickness}" CornerRadius="8" Padding="{TemplateBinding Padding}">
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="b" Property="Opacity" Value="0.86"/></Trigger>
              <Trigger Property="IsPressed" Value="True"><Setter TargetName="b" Property="Opacity" Value="0.72"/></Trigger>
              <Trigger Property="IsEnabled" Value="False"><Setter TargetName="b" Property="Opacity" Value="0.45"/></Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style x:Key="BtnPrimary" TargetType="Button" BasedOn="{StaticResource BtnBase}">
      <Setter Property="Background" Value="{StaticResource Accent}"/>
      <Setter Property="BorderBrush" Value="{StaticResource Accent}"/>
      <Setter Property="Foreground" Value="{StaticResource AccentText}"/>
    </Style>
    <Style x:Key="BtnSecondary" TargetType="Button" BasedOn="{StaticResource BtnBase}">
      <Setter Property="Background" Value="{StaticResource Surface2}"/>
      <Setter Property="BorderBrush" Value="{StaticResource Line}"/>
      <Setter Property="Foreground" Value="{StaticResource Text}"/>
    </Style>
    <Style x:Key="BtnGhost" TargetType="Button" BasedOn="{StaticResource BtnBase}">
      <Setter Property="Background" Value="Transparent"/>
      <Setter Property="BorderBrush" Value="Transparent"/>
      <Setter Property="Foreground" Value="{StaticResource Accent}"/>
      <Setter Property="Padding" Value="10,5"/>
    </Style>
    <Style x:Key="BtnDanger" TargetType="Button" BasedOn="{StaticResource BtnBase}">
      <Setter Property="Background" Value="Transparent"/>
      <Setter Property="BorderBrush" Value="{StaticResource Line}"/>
      <Setter Property="Foreground" Value="{StaticResource Err}"/>
      <Setter Property="FontWeight" Value="Normal"/>
      <Setter Property="Padding" Value="12,5"/>
    </Style>

    <Style x:Key="Seg" TargetType="RadioButton">
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Foreground" Value="{StaticResource Muted}"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="RadioButton">
            <Border x:Name="b" Background="Transparent" CornerRadius="6" Padding="10,6" Margin="2">
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsChecked" Value="True">
                <Setter TargetName="b" Property="Background" Value="{StaticResource Surface}"/>
                <Setter Property="Foreground" Value="{StaticResource Text}"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <Style TargetType="CheckBox">
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Foreground" Value="{StaticResource Text}"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="CheckBox">
            <StackPanel Orientation="Horizontal" Background="Transparent">
              <Border x:Name="box" Width="18" Height="18" CornerRadius="5" BorderThickness="1.5"
                      BorderBrush="{StaticResource LineHover}" Background="{StaticResource Field}" VerticalAlignment="Center">
                <Path x:Name="tick" Data="M 3.5 9 L 7.5 12.5 L 14 5" Stroke="{StaticResource AccentText}" StrokeThickness="2"
                      StrokeStartLineCap="Round" StrokeEndLineCap="Round" StrokeLineJoin="Round" Visibility="Collapsed" FlowDirection="LeftToRight"/>
              </Border>
              <ContentPresenter Margin="8,0,0,0" VerticalAlignment="Center"/>
            </StackPanel>
            <ControlTemplate.Triggers>
              <Trigger Property="IsChecked" Value="True">
                <Setter TargetName="box" Property="Background" Value="{StaticResource Accent}"/>
                <Setter TargetName="box" Property="BorderBrush" Value="{StaticResource Accent}"/>
                <Setter TargetName="tick" Property="Visibility" Value="Visible"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
  </Window.Resources>

  <Border x:Name="Root" Background="{{BG}}" Padding="28,24">
    <Grid>
      <Grid.RowDefinitions>
        <RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="*"/><RowDefinition Height="Auto"/>
      </Grid.RowDefinitions>

      <!-- Header -->
      <DockPanel Grid.Row="0">
        <Border DockPanel.Dock="Right" Background="{StaticResource Surface}" BorderBrush="{StaticResource Line}" BorderThickness="1"
                CornerRadius="10" Padding="14,8,6,8" VerticalAlignment="Center">
          <StackPanel Orientation="Horizontal">
            <Ellipse x:Name="DotV2" Width="8" Height="8" Fill="{StaticResource Muted}" VerticalAlignment="Center" Margin="0,0,10,0"/>
            <StackPanel VerticalAlignment="Center">
              <TextBlock x:Name="TxtV2Title" Text="v2rayN" FontWeight="SemiBold" FontSize="12" FlowDirection="LeftToRight" HorizontalAlignment="Right"/>
              <TextBlock x:Name="TxtV2" Text="…" Foreground="{StaticResource Muted}" FontSize="11" FlowDirection="LeftToRight"
                         HorizontalAlignment="Right" MaxWidth="240" TextTrimming="CharacterEllipsis"/>
            </StackPanel>
            <Button x:Name="BtnChange" Content="تغییر" Style="{StaticResource BtnGhost}" Margin="8,0,0,0" VerticalAlignment="Center"/>
          </StackPanel>
        </Border>
        <StackPanel VerticalAlignment="Center">
          <TextBlock Text="افزودن SSH به v2rayN" FontSize="22" FontWeight="SemiBold"/>
          <TextBlock Text="اتصال SSH با همان TUN و روتینگ v2rayN کار می‌کند" Style="{StaticResource Hint}" FontSize="12.5" Margin="0,4,0,0"/>
        </StackPanel>
      </DockPanel>

      <!-- New connection -->
      <Border Grid.Row="1" Style="{StaticResource Card}" Margin="0,20,0,0">
        <StackPanel>
          <TextBlock Text="اتصال جدید" Style="{StaticResource H2}"/>
          <TextBlock Text="متن اتصال را بچسبانید یا فیلدها را پر کنید. پشتیبانی: JSON سینگ‌باکس، ssh://، host:port:user:pass و متن فروشنده."
                     Style="{StaticResource Hint}" TextWrapping="Wrap" Margin="0,3,0,14"/>
          <Grid>
            <Grid.ColumnDefinitions><ColumnDefinition/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
            <Grid>
              <TextBox x:Name="TxtPaste" Height="66" AcceptsReturn="True" TextWrapping="Wrap" VerticalContentAlignment="Top"
                       VerticalScrollBarVisibility="Auto" FlowDirection="LeftToRight" FontFamily="Cascadia Mono, Consolas" FontSize="12"/>
              <TextBlock x:Name="HintPaste" Text="ssh://user:pass@host:22#name" Foreground="{StaticResource Muted}" Opacity="0.75"
                         Margin="12,9" IsHitTestVisible="False" FlowDirection="LeftToRight" HorizontalAlignment="Right"
                         VerticalAlignment="Top" FontFamily="Cascadia Mono, Consolas" FontSize="12"/>
            </Grid>
            <Button x:Name="BtnParse" Grid.Column="1" Content="خواندن" Style="{StaticResource BtnSecondary}" Margin="10,0,0,0" Padding="18,8"/>
          </Grid>

          <Grid Margin="0,18,0,0">
            <Grid.ColumnDefinitions>
              <ColumnDefinition Width="1.15*"/><ColumnDefinition Width="14"/><ColumnDefinition Width="1.6*"/><ColumnDefinition Width="14"/><ColumnDefinition Width="0.75*"/>
            </Grid.ColumnDefinitions>
            <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="14"/><RowDefinition Height="Auto"/></Grid.RowDefinitions>

            <StackPanel Grid.Row="0" Grid.Column="0">
              <TextBlock Text="نام" Style="{StaticResource Label}"/>
              <TextBox x:Name="TxtName"/>
            </StackPanel>
            <StackPanel Grid.Row="0" Grid.Column="2">
              <TextBlock Text="سرور (IP یا دامنه)" Style="{StaticResource Label}"/>
              <TextBox x:Name="TxtServer" FlowDirection="LeftToRight"/>
            </StackPanel>
            <StackPanel Grid.Row="0" Grid.Column="4">
              <TextBlock Text="پورت" Style="{StaticResource Label}"/>
              <TextBox x:Name="TxtPort" Text="22" FlowDirection="LeftToRight"/>
            </StackPanel>

            <StackPanel Grid.Row="2" Grid.Column="0">
              <TextBlock Text="نام کاربری" Style="{StaticResource Label}"/>
              <TextBox x:Name="TxtUser" FlowDirection="LeftToRight"/>
            </StackPanel>
            <StackPanel Grid.Row="2" Grid.Column="2">
              <TextBlock x:Name="LblKey" Text="فایل کلید خصوصی" Style="{StaticResource Label}" Visibility="Collapsed"/>
              <Grid x:Name="PanelKey" Visibility="Collapsed" Margin="0,0,0,12">
                <Grid.ColumnDefinitions><ColumnDefinition/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
                <TextBox x:Name="TxtKey" FlowDirection="LeftToRight"/>
                <Button x:Name="BtnKey" Grid.Column="1" Content="انتخاب" Style="{StaticResource BtnSecondary}" Margin="8,0,0,0" Padding="12,6" FontWeight="Normal"/>
              </Grid>
              <TextBlock x:Name="LblSecret" Text="رمز عبور" Style="{StaticResource Label}"/>
              <Grid>
                <PasswordBox x:Name="TxtPass" FlowDirection="LeftToRight" Padding="10,7,56,7"/>
                <TextBox x:Name="TxtPassPlain" FlowDirection="LeftToRight" Padding="10,7,56,7" Visibility="Collapsed"/>
                <Button x:Name="BtnEye" Content="نمایش" Style="{StaticResource BtnGhost}" HorizontalAlignment="Left"
                        FontSize="11.5" FontWeight="Normal" Padding="8,3" Margin="4,0"/>
              </Grid>
            </StackPanel>
            <StackPanel Grid.Row="2" Grid.Column="4">
              <TextBlock Text="ورود با" Style="{StaticResource Label}"/>
              <Border Background="{StaticResource Surface2}" CornerRadius="8" Padding="1">
                <UniformGrid Columns="2">
                  <RadioButton x:Name="RbPass" Content="رمز" Style="{StaticResource Seg}" IsChecked="True" GroupName="auth"/>
                  <RadioButton x:Name="RbKey"  Content="کلید" Style="{StaticResource Seg}" GroupName="auth"/>
                </UniformGrid>
              </Border>
            </StackPanel>
          </Grid>

          <DockPanel Margin="0,20,0,0">
            <Button x:Name="BtnAdd" DockPanel.Dock="Left" Content="افزودن به v2rayN" Style="{StaticResource BtnPrimary}" Padding="22,9"/>
            <Button x:Name="BtnTest" DockPanel.Dock="Left" Content="تست اتصال" Style="{StaticResource BtnSecondary}" Margin="10,0,0,0" Padding="18,9"/>
            <Button x:Name="BtnClear" DockPanel.Dock="Left" Content="پاک کردن فرم" Style="{StaticResource BtnGhost}" Margin="6,0,0,0" FontWeight="Normal" Foreground="{StaticResource Muted}"/>
            <TextBlock x:Name="TxtStatus" VerticalAlignment="Center" Margin="12,0,0,0" TextWrapping="Wrap" FontSize="12.5"/>
          </DockPanel>
        </StackPanel>
      </Border>

      <!-- Existing -->
      <Border Grid.Row="2" Style="{StaticResource Card}" Margin="0,16,0,0" Padding="22,16,22,8">
        <DockPanel>
          <DockPanel DockPanel.Dock="Top" Margin="0,0,0,4">
            <Button x:Name="BtnRefresh" DockPanel.Dock="Right" Content="بازخوانی" Style="{StaticResource BtnGhost}" FontWeight="Normal"/>
            <StackPanel Orientation="Horizontal" VerticalAlignment="Center">
              <TextBlock Text="SSH های موجود در v2rayN" Style="{StaticResource H2}"/>
              <Border Background="{StaticResource Surface2}" CornerRadius="9" Padding="8,1" Margin="8,0,0,0" VerticalAlignment="Center">
                <TextBlock x:Name="TxtCount" Text="0" FontSize="11.5" Foreground="{StaticResource Muted}"/>
              </Border>
            </StackPanel>
          </DockPanel>
          <Grid>
            <TextBlock x:Name="TxtEmpty" Text="هنوز اتصال SSH اضافه نشده" Style="{StaticResource Hint}" FontSize="12.5"
                       HorizontalAlignment="Center" VerticalAlignment="Center" Margin="0,18"/>
            <ScrollViewer VerticalScrollBarVisibility="Auto">
              <ItemsControl x:Name="ListSsh">
                <ItemsControl.ItemTemplate>
                  <DataTemplate>
                    <Border BorderBrush="{StaticResource Line}" BorderThickness="0,1,0,0" Padding="2,12">
                      <DockPanel>
                        <Button DockPanel.Dock="Right" Content="حذف" Style="{StaticResource BtnDanger}" Tag="{Binding Id}" VerticalAlignment="Center"/>
                        <StackPanel VerticalAlignment="Center">
                          <TextBlock Text="{Binding Name}" FontWeight="SemiBold" FontSize="13.5"/>
                          <TextBlock Text="{Binding Detail}" Foreground="{StaticResource Muted}" FontSize="12" Margin="0,3,0,0"
                                     FlowDirection="LeftToRight" HorizontalAlignment="Left" FontFamily="Cascadia Mono, Consolas"/>
                        </StackPanel>
                      </DockPanel>
                    </Border>
                  </DataTemplate>
                </ItemsControl.ItemTemplate>
              </ItemsControl>
            </ScrollViewer>
          </Grid>
        </DockPanel>
      </Border>

      <!-- Footer -->
      <DockPanel Grid.Row="3" Margin="2,14,2,0">
        <TextBlock DockPanel.Dock="Right" Text="پشتیبان قبل از هر تغییر · همه چیز روی همین کامپیوتر" Style="{StaticResource Hint}" FontSize="11.5" VerticalAlignment="Center"/>
        <CheckBox x:Name="ChkRestart" IsChecked="True" Content="بعد از هر تغییر، v2rayN خودکار ری‌استارت شود" VerticalAlignment="Center"/>
      </DockPanel>
    </Grid>
  </Border>
</Window>
'@

# =====================================================================
#  TOOL 4 : My Direct Domains  (domains that bypass the VPN)
# =====================================================================
$RuleDomain = 'My Direct'
$RuleIp     = 'My Direct IP'
$DnsTag     = 'my-direct'
$AdsTag     = 'ads-block'
$FallbackIranDns = '217.218.155.155'

# ---- backup text file (next to the .bat; falls back to Documents) ----
function Get-DataFile {
  $bat = $env:D4_BAT
  $dir = if ($bat) { Split-Path -Parent $bat } else { $PWD.Path }
  $file = Join-Path $dir 'direct-domains.txt'
  try {
    if (Test-Path -LiteralPath $file) { $fs = [IO.File]::Open($file, 'Open', 'ReadWrite', 'Read'); $fs.Close() }
    else { [IO.File]::WriteAllText($file, '', $Utf8NoBom); Remove-Item -LiteralPath $file -Force }
    return $file
  } catch {
    $alt = Join-Path ([Environment]::GetFolderPath('MyDocuments')) 'v2rayN-direct-domains.txt'
    Write-Log "Data dir not writable, using $alt"
    return $alt
  }
}

# ---- parsing / normalising ----
function ConvertTo-Entry([string]$raw) {
  $l = "$raw"
  $hash = $l.IndexOf('#'); if ($hash -ge 0) { $l = $l.Substring(0, $hash) }
  $l = $l.Trim().Trim(',', ';').Trim()
  if (-not $l) { return $null }
  $l = $l -replace '[\u200c\u200f\u200e]', ''
  if ($l -match '^(?<p>geosite|domain|full|keyword|regexp|ext):(?<v>\S.*)$') { return @{ Kind = 'domain'; Value = ($Matches.p + ':' + $Matches.v.Trim()) } }
  if ($l -match '^geoip:(?<v>\S+)$') { return @{ Kind = 'ip'; Value = 'geoip:' + $Matches.v.ToLower() } }
  $h = $l.ToLower() -replace '^[a-z][a-z0-9+\-.]*://', ''
  if ($h -notmatch '^\d{1,3}(\.\d{1,3}){3}/\d{1,2}$') { $h = ($h -split '[/?#]')[0] }
  $h = $h -replace '^[^@]*@', ''
  if ($h -match '^\d{1,3}(\.\d{1,3}){3}(/\d{1,2})?$') {
    $ipPart = ($h -split '/')[0]; $ok = $true; foreach ($o in ($ipPart -split '\.')) { if ([int]$o -gt 255) { $ok = $false } }
    $cidr = if ($h -match '/(\d+)$') { [int]$Matches[1] } else { 0 }
    if ($ok -and $cidr -le 32) { return @{ Kind = 'ip'; Value = $h } }
    return @{ Error = $l }
  }
  $h = ($h -replace ':\d+$', '') -replace '^\*\.', '' -replace '^www\.', ''
  $h = $h.Trim('.')
  try { $h = (New-Object Globalization.IdnMapping).GetAscii($h) } catch { return @{ Error = $l } }
  if ($h -match '^([a-z0-9]([a-z0-9\-]{0,61}[a-z0-9])?\.)+[a-z0-9\-]{2,63}$') { return @{ Kind = 'domain'; Value = "domain:$h" } }
  return @{ Error = $l }
}

function ConvertFrom-DomainText([string]$text) {
  $dom = New-Object System.Collections.ArrayList; $ip = New-Object System.Collections.ArrayList; $bad = New-Object System.Collections.ArrayList
  $seen = @{}
  foreach ($rawLine in ("$text" -split "\r?\n")) {
    $noComment = $rawLine; $h = $noComment.IndexOf('#'); if ($h -ge 0) { $noComment = $noComment.Substring(0, $h) }
    foreach ($tok in ($noComment -split '[,;\s]+')) {
      $e = ConvertTo-Entry $tok
      if (-not $e) { continue }
      if ($e.Error) { [void]$bad.Add($e.Error); continue }
      if ($seen.ContainsKey($e.Value)) { continue }; $seen[$e.Value] = 1
      if ($e.Kind -eq 'ip') { [void]$ip.Add($e.Value) } else { [void]$dom.Add($e.Value) }
    }
  }
  [pscustomobject]@{ Domains = $dom.ToArray(); Ips = $ip.ToArray(); Bad = $bad.ToArray()
                     Count = ($dom.Count + $ip.Count) }
}

function Format-Entries($p) {
  $out = New-Object System.Collections.ArrayList
  foreach ($d in $p.Domains) { [void]$out.Add(($d -replace '^domain:', '')) }
  foreach ($i in $p.Ips) { [void]$out.Add($i) }
  $out.ToArray()
}

# ---- text file I/O ----
function Read-DataFile {
  if (-not (Test-Path -LiteralPath $script:DataFile)) { return '' }
  [IO.File]::ReadAllText($script:DataFile, [Text.Encoding]::UTF8)
}
function Save-DataFile($p) {
  $lines = @('# My direct domains for v2rayN - one per line (domain, IP/CIDR, geosite:xxx, geoip:xx).',
             '# These bypass the VPN. Keep this file: run the tool again to re-apply after a v2rayN reset.', '')
  $lines += Format-Entries $p
  [IO.File]::WriteAllText($script:DataFile, (($lines -join "`r`n") + "`r`n"), (New-Object Text.UTF8Encoding $true))
}

# ---- v2rayN: routing + dns ----
# PowerShell 5 returns a JSON array as ONE object; this always yields the real elements.
function Read-JsonArray([string]$json) {
  $o = ConvertFrom-Json -InputObject $json
  foreach ($i in $o) { $i }
}

function Get-AppliedEntries {
  $dom = @(); $ip = @()
  $rows = @(Use-Db { param($db) Q $db 'select RuleSet from RoutingItem where IsActive = 1' $null })
  if (-not $rows.Count) { $rows = @(Use-Db { param($db) Q $db 'select RuleSet from RoutingItem limit 1' $null }) }
  foreach ($r in $rows) {
    try { $rules = @(Read-JsonArray ([string]$r['RuleSet'])) } catch { continue }
    foreach ($x in @($rules)) {
      if ($x.Remarks -eq $RuleDomain) { $dom += @($x.Domain) }
      if ($x.Remarks -eq $RuleIp)     { $ip  += @($x.Ip) }
    }
  }
  [pscustomobject]@{ Domains = @($dom | Where-Object { $_ }); Ips = @($ip | Where-Object { $_ }) }
}

function Update-Routing($p) {
  Use-Db {
    param($db)
    foreach ($row in @(Q $db 'select Id, RuleSet from RoutingItem' $null)) {
      $rules = @(); try { $rules = @(Read-JsonArray ([string]$row['RuleSet'])) } catch { continue }
      $rules = @($rules | Where-Object { $_.Remarks -ne $RuleDomain -and $_.Remarks -ne $RuleIp })
      $add = @()
      if ($p.Domains.Count) { $add += [pscustomobject][ordered]@{ Id = [string](Get-Random -Minimum ([long]4000000000000000000) -Maximum ([long]4999999999999999999)); OutboundTag = 'direct'; Domain = @($p.Domains); Enabled = $true; Remarks = $RuleDomain } }
      if ($p.Ips.Count)     { $add += [pscustomobject][ordered]@{ Id = [string](Get-Random -Minimum ([long]4000000000000000000) -Maximum ([long]4999999999999999999)); OutboundTag = 'direct'; Ip = @($p.Ips); Enabled = $true; Remarks = $RuleIp } }
      $all = @($add) + @($rules)
      $json = ConvertTo-Json -InputObject @($all) -Depth 8 -Compress
      Q $db 'update RoutingItem set RuleSet = ?, RuleNum = ? where Id = ?' @($json, $all.Count, $row['Id']) | Out-Null
    }
  }
}

function Update-DnsText([string]$text, $p) {
  if (-not $text -or -not $text.Trim()) { return $text }
  try { $cfg = ConvertFrom-Json -InputObject $text } catch { return $text }
  if (-not $cfg.servers) { return $text }
  $ours = { param($s) ($s -is [pscustomobject]) -and ($s.tag -eq $DnsTag -or $s.tag -eq $AdsTag) }
  $hadAds = @($cfg.servers | Where-Object { ($_ -is [pscustomobject]) -and $_.tag -eq $AdsTag }).Count -gt 0
  $servers = @($cfg.servers | Where-Object { -not (& $ours $_) })
  $hasHosts = [bool]($cfg.PSObject.Properties['hosts'] -and $cfg.hosts)
  $adsKey = 'geosite:category-ads-all'
  if ($p.Domains.Count) {
    $iran = $servers | Where-Object { $_ -is [pscustomobject] -and $_.expectedIPs -contains 'geoip:ir' } | Select-Object -First 1
    $addr = if ($iran) { [string]$iran.address } else { $FallbackIranDns }
    $mine = [pscustomobject][ordered]@{ address = $addr; domains = @($p.Domains); skipFallback = $true; tag = $DnsTag }
    $new = @($mine)
    # A "hosts" blackhole for ad domains beats every DNS server, so a site that is also on the ad list
    # (e.g. an ad network's panel) would resolve to 127.0.0.1. Move that block to a DNS server that is
    # placed AFTER our direct server: our domains resolve normally, every other ad domain stays blocked.
    if ($hasHosts -and $cfg.hosts.PSObject.Properties[$adsKey]) {
      $cfg.hosts.PSObject.Properties.Remove($adsKey)
      $new += [pscustomobject][ordered]@{ address = 'rcode://refused'; domains = @($adsKey); skipFallback = $true; tag = $AdsTag }
    } elseif ($hadAds) {
      $new += [pscustomobject][ordered]@{ address = 'rcode://refused'; domains = @($adsKey); skipFallback = $true; tag = $AdsTag }
    }
    $servers = $new + $servers
  } elseif ($hadAds) {
    # list is empty again: restore the original hosts-based ad block
    $cur = if ($hasHosts) { $cfg.hosts } else { [pscustomobject]@{} }
    if (-not $cur.PSObject.Properties[$adsKey]) {
      $h = [ordered]@{ $adsKey = '127.0.0.1' }
      foreach ($pr in $cur.PSObject.Properties) { $h[$pr.Name] = $pr.Value }
      $cfg | Add-Member -NotePropertyName hosts -NotePropertyValue ([pscustomobject]$h) -Force
    }
  }
  $cfg.servers = $servers
  ConvertTo-Json -InputObject $cfg -Depth 12
}

function Update-Dns($p) {
  Use-Db {
    param($db)
    foreach ($row in @(Q $db 'select Id, NormalDNS, TunDNS from DNSItem' $null)) {
      $n = Update-DnsText ([string]$row['NormalDNS']) $p
      $t = Update-DnsText ([string]$row['TunDNS']) $p
      Q $db 'update DNSItem set NormalDNS = ?, TunDNS = ? where Id = ?' @($n, $t, $row['Id']) | Out-Null
    }
  }
}

function Update-V2rayN($p) {
  Backup-Db
  Update-Routing $p
  Update-Dns $p
  Write-Log "Applied direct list: $($p.Domains.Count) domains, $($p.Ips.Count) ips"
}

function Restart-V2rayN {
  $root = $script:V.Root
  Get-Process -ErrorAction SilentlyContinue | Where-Object {
    try { $_.Path -and $_.Path.StartsWith($root, [StringComparison]::OrdinalIgnoreCase) } catch { $false }
  } | Stop-Process -Force -ErrorAction SilentlyContinue
  Start-Sleep -Milliseconds 900
  Start-Process -FilePath $script:V.Exe -WorkingDirectory $root
  Write-Log 'Restarted v2rayN'
}

if ($env:D4_SELFTEST) { return }

# =====================================================================
#  UI
# =====================================================================
$dark = $false
try { $dark = ((Get-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize' -ErrorAction Stop).AppsUseLightTheme -eq 0) } catch {}
if ($env:D4_THEME -eq 'dark') { $dark = $true } elseif ($env:D4_THEME -eq 'light') { $dark = $false }
$Tok = if ($dark) {
  @{ BG = '#0E1014'; SURFACE = '#161920'; SURFACE2 = '#1E222B'; FIELD = '#111318'; LINE = '#272C36'; LINEHOVER = '#363C48'
     TEXT = '#E7E9EE'; MUTED = '#8A92A0'; ACCENT = '#4C8DFF'; ACCENTTEXT = '#FFFFFF'; OK = '#3FB950'; ERR = '#FF6B63'; WARN = '#E3A93B' }
} else {
  @{ BG = '#F5F6F8'; SURFACE = '#FFFFFF'; SURFACE2 = '#F0F2F5'; FIELD = '#FFFFFF'; LINE = '#E2E5EA'; LINEHOVER = '#C9CED6'
     TEXT = '#15171C'; MUTED = '#6B7280'; ACCENT = '#2563EB'; ACCENTTEXT = '#FFFFFF'; OK = '#15803D'; ERR = '#C2261D'; WARN = '#B45309' }
}

$Xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="دامنه‌های مستقیم v2rayN" Width="720" Height="720" MinWidth="620" MinHeight="600"
        WindowStartupLocation="CenterScreen" FlowDirection="RightToLeft"
        FontFamily="Segoe UI" FontSize="13" Foreground="{{TEXT}}" Background="{{BG}}"
        UseLayoutRounding="True" SnapsToDevicePixels="True" TextOptions.TextFormattingMode="Display">
  {{RESOURCES}}
  <Border x:Name="Root" Background="{{BG}}" Padding="28,24">
    <Grid>
      <Grid.RowDefinitions>
        <RowDefinition Height="Auto"/><RowDefinition Height="*"/><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/>
      </Grid.RowDefinitions>

      <DockPanel Grid.Row="0">
        <Border DockPanel.Dock="Right" Background="{StaticResource Surface}" BorderBrush="{StaticResource Line}" BorderThickness="1"
                CornerRadius="10" Padding="14,8,6,8" VerticalAlignment="Center">
          <StackPanel Orientation="Horizontal">
            <Ellipse x:Name="DotV2" Width="8" Height="8" Fill="{StaticResource Muted}" VerticalAlignment="Center" Margin="0,0,10,0"/>
            <StackPanel VerticalAlignment="Center">
              <TextBlock x:Name="TxtV2Title" Text="v2rayN" FontWeight="SemiBold" FontSize="12" FlowDirection="LeftToRight" HorizontalAlignment="Right"/>
              <TextBlock x:Name="TxtV2" Text="…" Foreground="{StaticResource Muted}" FontSize="11" FlowDirection="LeftToRight"
                         HorizontalAlignment="Right" MaxWidth="220" TextTrimming="CharacterEllipsis"/>
            </StackPanel>
            <Button x:Name="BtnChange" Content="تغییر" Style="{StaticResource BtnGhost}" Margin="8,0,0,0" VerticalAlignment="Center"/>
          </StackPanel>
        </Border>
        <StackPanel VerticalAlignment="Center">
          <TextBlock Text="دامنه‌های مستقیم" FontSize="22" FontWeight="SemiBold"/>
          <TextBlock Text="سایت‌هایی که باید بدون VPN و با DNS ایران باز شوند" Style="{StaticResource Hint}" FontSize="12.5" Margin="0,4,0,0"/>
        </StackPanel>
      </DockPanel>

      <Border Grid.Row="1" Style="{StaticResource Card}" Margin="0,20,0,0">
        <DockPanel>
          <StackPanel DockPanel.Dock="Top">
            <DockPanel>
              <Border DockPanel.Dock="Left" Background="{StaticResource Surface2}" CornerRadius="9" Padding="9,2" VerticalAlignment="Center">
                <TextBlock x:Name="TxtCount" Text="0" FontSize="11.5" Foreground="{StaticResource Muted}"/>
              </Border>
              <TextBlock Text="لیست" Style="{StaticResource H2}"/>
            </DockPanel>
            <TextBlock Text="هر خط یک مورد: دامنه (مثل example.com، زیردامنه‌ها هم شامل می‌شوند)، IP یا CIDR، یا geosite:xxx / geoip:xx. آدرس کامل سایت هم قبول است."
                       Style="{StaticResource Hint}" TextWrapping="Wrap" Margin="0,4,0,12"/>
          </StackPanel>
          <Grid>
            <TextBox x:Name="TxtList" AcceptsReturn="True" TextWrapping="NoWrap" VerticalContentAlignment="Top"
                     VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Auto" FlowDirection="LeftToRight"
                     FontFamily="Cascadia Mono, Consolas" FontSize="13" Padding="12,10"/>
            <TextBlock x:Name="HintList" Text="vividvisual.com&#10;vividdownload.com&#10;yektanet.com" Foreground="{StaticResource Muted}" Opacity="0.6"
                       Margin="13,11" IsHitTestVisible="False" FlowDirection="LeftToRight" HorizontalAlignment="Left" VerticalAlignment="Top"
                       FontFamily="Cascadia Mono, Consolas" FontSize="13"/>
          </Grid>
        </DockPanel>
      </Border>

      <DockPanel Grid.Row="2" Margin="0,16,0,0">
        <Button x:Name="BtnApply" DockPanel.Dock="Left" Content="ذخیره و اعمال" Style="{StaticResource BtnPrimary}" Padding="24,9"/>
        <Button x:Name="BtnReload" DockPanel.Dock="Left" Content="خواندن از فایل" Style="{StaticResource BtnSecondary}" Margin="10,0,0,0" Padding="16,9"/>
        <Button x:Name="BtnOpen" DockPanel.Dock="Left" Content="باز کردن فایل متنی" Style="{StaticResource BtnGhost}" Margin="6,0,0,0" FontWeight="Normal"/>
        <TextBlock x:Name="TxtStatus" VerticalAlignment="Center" Margin="12,0,0,0" TextWrapping="Wrap" FontSize="12.5"/>
      </DockPanel>

      <DockPanel Grid.Row="3" Margin="2,14,2,0">
        <TextBlock x:Name="TxtFile" DockPanel.Dock="Right" Style="{StaticResource Hint}" FontSize="11.5" FlowDirection="LeftToRight"
                   VerticalAlignment="Center" MaxWidth="330" TextTrimming="CharacterEllipsis"/>
        <CheckBox x:Name="ChkRestart" IsChecked="True" Content="بعد از اعمال، v2rayN خودکار ری‌استارت شود" VerticalAlignment="Center"/>
      </DockPanel>
    </Grid>
  </Border>
</Window>
'@
$resBlock = [regex]::Match($script:SharedXaml, '(?s)<Window\.Resources>.*?</Window\.Resources>').Value
$Xaml = $Xaml.Replace('{{RESOURCES}}', $resBlock)
foreach ($k in $Tok.Keys) { $Xaml = $Xaml.Replace("{{$k}}", $Tok[$k]) }
$win = [Windows.Markup.XamlReader]::Parse($Xaml)
$ui = @{}
foreach ($n in 'DotV2','TxtV2Title','TxtV2','BtnChange','TxtCount','TxtList','HintList','BtnApply','BtnReload','BtnOpen','TxtStatus','TxtFile','ChkRestart') { $ui[$n] = $win.FindName($n) }
$Brush = @{ ok = $win.Resources['Ok']; err = $win.Resources['Err']; muted = $win.Resources['Muted']
            warn = (New-Object Windows.Media.SolidColorBrush ([Windows.Media.ColorConverter]::ConvertFromString($Tok.WARN))) }

function Set-Status([string]$msg, [string]$kind = 'muted') { $ui.TxtStatus.Text = $msg; $ui.TxtStatus.Foreground = $Brush[$kind] }
function Update-Ui { $win.Dispatcher.Invoke([action] {}, [Windows.Threading.DispatcherPriority]::Background) }
function Set-Ready([bool]$ok) { foreach ($b in 'BtnApply','BtnReload') { $ui[$b].IsEnabled = $ok } }
function Update-Count { $p = ConvertFrom-DomainText $ui.TxtList.Text; $ui.TxtCount.Text = [string]$p.Count }
function Show-Install {
  if ($script:V) {
    $ui.TxtV2Title.Text = if ($script:V.Version) { "v2rayN  $($script:V.Version)" } else { 'v2rayN' }
    $ui.TxtV2.Text = $script:V.Root; $ui.TxtV2.ToolTip = $script:V.Root; $ui.DotV2.Fill = $Brush.ok
  } else { $ui.TxtV2Title.Text = 'v2rayN'; $ui.TxtV2.Text = 'پیدا نشد'; $ui.DotV2.Fill = $Brush.err }
}

function Get-SyncStatus {
  $p = ConvertFrom-DomainText $ui.TxtList.Text
  $a = Get-AppliedEntries
  $want = @(Format-Entries $p | Sort-Object)
  $have = @((@($a.Domains | ForEach-Object { $_ -replace '^domain:', '' }) + @($a.Ips)) | Sort-Object)
  if (-not $want.Count -and -not $have.Count) { Set-Status '' 'muted'; return }
  if (($want -join '|') -eq ($have -join '|')) { Set-Status "✓ $($want.Count) مورد در v2rayN فعال است" 'ok' }
  elseif ($want.Count) { Set-Status 'لیست با v2rayN یکی نیست · «ذخیره و اعمال» را بزنید' 'warn' }
  else { Set-Status 'لیست خالی است ولی v2rayN موردی دارد · برای حذف، «ذخیره و اعمال» را بزنید' 'warn' }
}

function Load-List {
  $txt = Read-DataFile
  if ($txt.Trim()) {
    $p = ConvertFrom-DomainText $txt
    $ui.TxtList.Text = (Format-Entries $p) -join "`r`n"
  } else {
    $a = Get-AppliedEntries
    $ui.TxtList.Text = ((@($a.Domains | ForEach-Object { $_ -replace '^domain:', '' }) + @($a.Ips)) -join "`r`n")
  }
  Update-Count; Get-SyncStatus
}

function Select-Install($inst) {
  try {
    if (-not $inst.HasDb) { throw 'این v2rayN هنوز یک‌بار اجرا نشده (guiNDB.db وجود ندارد). یک‌بار v2rayN را باز و بسته کنید.' }
    Use-Install $inst; Show-Install; Set-Ready $true; Load-List
  } catch { $script:V = $null; Show-Install; Set-Ready $false; Set-Status $_.Exception.Message 'err'; Write-Log "Select-Install failed: $($_.Exception.Message)" }
}

$script:DataFile = Get-DataFile
$ui.TxtFile.Text = $script:DataFile; $ui.TxtFile.ToolTip = $script:DataFile

$ui.TxtList.Add_TextChanged({ $ui.HintList.Visibility = if ($ui.TxtList.Text) { 'Collapsed' } else { 'Visible' }; Update-Count })

$ui.BtnApply.Add_Click({
  $p = ConvertFrom-DomainText $ui.TxtList.Text
  if ($p.Bad.Count) {
    $shown = ($p.Bad | Select-Object -First 3) -join '  ،  '
    Set-Status ("مورد نامعتبر: $shown" + $(if ($p.Bad.Count -gt 3) { " و $($p.Bad.Count - 3) مورد دیگر" } else { '' })) 'err'; return
  }
  try {
    Save-DataFile $p
    Update-V2rayN $p
    $ui.TxtList.Text = (Format-Entries $p) -join "`r`n"
    $msg = if ($p.Count) { "$($p.Count) مورد اعمال شد" } else { 'همه‌ی موارد حذف شد' }
    if ($ui.ChkRestart.IsChecked) {
      try { Restart-V2rayN; Set-Status "$msg · v2rayN ری‌استارت شد" 'ok' } catch { Set-Status "$msg · ری‌استارت v2rayN ناموفق بود" 'warn' }
    } else { Set-Status "$msg · برای اثر، v2rayN را از Tray ببندید و دوباره باز کنید" 'ok' }
  } catch { Set-Status ("اعمال ناموفق بود: " + $_.Exception.Message) 'err'; Write-Log "Apply failed: $($_.Exception.Message)" }
})
$ui.BtnReload.Add_Click({ Load-List; Set-Status 'از فایل متنی خوانده شد.' 'muted' })
$ui.BtnOpen.Add_Click({
  try {
    if (-not (Test-Path -LiteralPath $script:DataFile)) { Save-DataFile (ConvertFrom-DomainText $ui.TxtList.Text) }
    Start-Process notepad.exe -ArgumentList ('"' + $script:DataFile + '"')
  } catch { Set-Status 'باز کردن فایل ناموفق بود.' 'err' }
})
$ui.BtnChange.Add_Click({
  Set-Status 'در حال جستجوی v2rayN…' 'muted'; Update-Ui
  $all = @(Find-V2rayN); Set-Status '' 'muted'
  $menu = New-Object Windows.Controls.ContextMenu; $menu.FlowDirection = 'LeftToRight'
  foreach ($i in $all) {
    $mi = New-Object Windows.Controls.MenuItem
    $mi.Header = ('{0}   (v{1}){2}' -f $i.Root, $i.Version, $(if ($i.HasDb) { '' } else { '  - not initialized' }))
    $mi.Tag = $i; $mi.IsChecked = ($script:V -and $script:V.Exe -eq $i.Exe)
    $mi.Add_Click({ param($s, $e) Select-Install $s.Tag }); [void]$menu.Items.Add($mi)
  }
  if ($all.Count) { [void]$menu.Items.Add((New-Object Windows.Controls.Separator)) }
  $browse = New-Object Windows.Controls.MenuItem; $browse.Header = 'Browse for v2rayN.exe …'
  $browse.Add_Click({
    $d = New-Object Microsoft.Win32.OpenFileDialog; $d.Filter = 'v2rayN|v2rayN.exe'; $d.Title = 'v2rayN.exe'
    if ($d.ShowDialog($win)) {
      $root = Split-Path $d.FileName
      Select-Install ([pscustomobject]@{ Exe = $d.FileName; Root = $root; Version = [string](Get-Item $d.FileName).VersionInfo.FileVersion
                                          HasDb = (Test-Path (Join-Path $root 'guiConfigs\guiNDB.db')) })
    }
  })
  [void]$menu.Items.Add($browse); $menu.PlacementTarget = $ui.BtnChange; $menu.Placement = 'Bottom'; $menu.IsOpen = $true
})

function Initialize-App {
  $found = @(Find-V2rayN -Quick)
  if (-not $found.Count) { Set-Status 'در C:\app پیدا نشد؛ در حال جستجوی جاهای دیگر…' 'muted'; Update-Ui; $found = @(Find-V2rayN) }
  if ($found.Count) { Select-Install $found[0] }
  else { Show-Install; Set-Ready $false; Set-Status 'v2rayN پیدا نشد. از «تغییر» مسیر v2rayN.exe را انتخاب کنید.' 'err' }
}

if ($env:D4_RENDER) { return }
$win.Add_ContentRendered({ Initialize-App })
[void]$win.ShowDialog()
