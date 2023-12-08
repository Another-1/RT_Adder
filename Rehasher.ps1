$max_rehash_qty = 10
$max_rehash_size_bytes = 10 * 1024 * 1024 * 1024 # 10 гигов

Write-Output 'Проверяем версию Powershell...'
If ( $PSVersionTable.PSVersion -lt [version]'7.1.0.0') {
    Write-Host 'У вас слишком древний Powershell, обновитесь с https://github.com/PowerShell/PowerShell#get-powershell ' -ForegroundColor Red
    Pause
    Exit
}

Write-Output 'Подгружаем функции'
. "$PSScriptRoot\_functions.ps1"

if ( -not ( [bool](Get-InstalledModule -Name PsIni -ErrorAction SilentlyContinue) ) ) {
    Write-Output 'Не установлен модуль PSIni для чтения настроек Web-TLO, ставим...'
    Install-Module -Name PsIni -Scope CurrentUser -Force
}
if ( -not ( [bool](Get-InstalledModule -Name PSSQLite -ErrorAction SilentlyContinue) ) ) {
    Write-Output 'Не установлен модуль PSSQLite для работы с SQLite, ставим...'
    Install-Module -Name PSSQLite -Scope CurrentUser -Force
}

If ( -not ( Test-path "$PSScriptRoot\_settings.ps1" )) {
    Set-Preferences # $tlo_path $max_seeds $get_hidden $get_blacklist $get_news $tg_token $tg_chat
}
else { . "$PSScriptRoot\_settings.ps1" }

if ( !$max_rehash_qty -or !$max_rehash_size_bytes ) {
    Write-Host 'Задайте ограничения на пачку в _settings.ps1 или во мне самом' -ForegroundColor Red
    exit
}

Write-Output 'Читаем настройки Web-TLO'

$ini_path = $tlo_path + '\data\config.ini'
$ini_data = Get-IniContent $ini_path

Write-Output 'Получаем из TLO данные о клиентах'
$clients = @{}
$ini_data.keys | Where-Object { $_ -match '^torrent-client' -and $ini_data[$_].client -eq 'qbittorrent' } | ForEach-Object {
    $clients[$ini_data[$_].id] = @{ Login = $ini_data[$_].login; Password = $ini_data[$_].password; Name = $ini_data[$_].comment; IP = $ini_data[$_].hostname; Port = $ini_data[$_].port; }
} 

foreach ($clientkey in $clients.Keys ) {
    $client = $clients[ $clientkey ]
    Initialize-Client( $client )
    $client_torrents = Get-Torrents $client '' $true $nul $clientkey
    $clients_torrents += $client_torrents
}

$db_data = @{}
$separator = Get-Separator
$database_path = $PSScriptRoot + $separator + 'rehashes.db'
Write-Output 'Подключаемся к БД'
$conn = Open-Database $database_path
Invoke-SqliteQuery -Query 'CREATE TABLE IF NOT EXISTS rehash_dates (hash VARCHAR PRIMARY KEY NOT NULL, rehash_date INT)' -SQLiteConnection $conn
Write-Output 'Выгружаем из БД даты рехэшей'
Invoke-SqliteQuery -Query 'SELECT * FROM rehash_dates' -SQLiteConnection $conn | ForEach-Object { $db_data += @{$_.hash = $_.rehash_date } }

$full_data_sorted = [System.Collections.ArrayList]::new()
Write-Output 'Ищем раздачи из клиентов в БД рехэшей'
$clients_torrents | ForEach-Object {
    if ( !$_.infohash_v1 -or $nul -eq $_.infohash_v1 -or $_.infohash_v1 -eq '' ) { $_.infohash_v1 = $_.hash }

    $full_data_sorted.Add( [PSCustomObject]@{ hash = $_.infohash_v1; rehash_date = $( $db_data[$_.infohash_v1] -gt 0 ? $db_data[$_.infohash_v1] : 0 ); client_key = $_.client_key; size = $_.size } ) | Out-Null
}
Write-Output 'Сортируем всё по дате рехэша и размеру'
$full_data_sorted = $full_data_sorted | Sort-Object -Descending -Property size | Sort-Object -Property rehash_date -Stable

$sum_cnt = 0
$sum_size = 0
$full_data_sorted | ForEach-Object {
    Start-Rehash $clients[$_.client_key] $_.hash
    if ( !$db_data[$_.hash] ) {
        Invoke-SqliteQuery -Query "INSERT INTO rehash_dates (hash, rehash_date) VALUES (@hash, @epoch )" -SqlParameters @{ hash = $_.hash; epoch = ( Get-Date -UFormat %s ) }-SQLiteConnection $conn
    }
    else {
        Invoke-SqliteQuery -Query "UPDATE rehash_dates SET rehash_date = @epoch WHERE hash = @hash" -SqlParameters @{ hash = $_.hash; epoch = ( Get-Date -UFormat %s ) } -SQLiteConnection $conn
    }
    $sum_cnt += 1
    $sum_size += $_.size
    if ( $sum_cnt -ge $max_rehash_qty -or $sum_size -ge $max_rehash_size_bytes) {
        break
    }
}

$conn.Close()