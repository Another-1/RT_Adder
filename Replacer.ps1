Write-Output 'Проверяем версию Powershell...'
If ( $PSVersionTable.PSVersion -lt [version]'7.1.0.0') {
    Write-Host 'У вас слишком древний Powershell, обновитесь с https://github.com/PowerShell/PowerShell#get-powershell ' -ForegroundColor Red
    Pause
    Exit
}

Write-Output 'Подгружаем функции'
. "$PSScriptRoot\_functions.ps1"

while ( $true ) {
    $TLO_OK = 'Y'
    If ( ( $prompt = Read-host -Prompt "У вас установлен и настроен Web-TLO? (Y/N) [$TLO_OK]" ) -ne '' ) {
        $TLO_OK = $prompt.ToUpper() 
    }
    If ( $TLO_OK -match '^[Y|N]$' ) { break }
    Write-Host 'Я ничего не понял, проверьте ввод' -ForegroundColor Red
}

switch ( $TLO_OK ) {
    'Y' {
        If ( -not ( Test-path "$PSScriptRoot\_settings.ps1" ) ) {
            Set-Preferences
        }
        else { . "$PSScriptRoot\_settings.ps1" }
        Write-Output 'Читаем настройки Web-TLO'
        $ini_path = $tlo_path + '\data\config.ini'
        $ini_data = Get-IniContent $ini_path
        $clients = @{}
        Write-Host 'Получаем из TLO данные о клиентах'
        $ini_data.keys | Where-Object { $_ -match '^torrent-client' -and $ini_data[$_].client -eq 'qbittorrent' } | ForEach-Object {
            $clients[$ini_data[$_].id] = @{ Login = $ini_data[$_].login; Password = $ini_data[$_].password; Name = $ini_data[$_].comment; IP = $ini_data[$_].hostname; Port = $ini_data[$_].port; }
            $clients_sort = [ordered]@{}
            $clients.GetEnumerator() | Sort-Object -Property key | ForEach-Object { $clients_sort[$_.key] = $clients[$_.key] }
            $clients = $clients_sort
        } 
        Remove-Variable -Name clients_sort -ErrorAction SilentlyContinue
        $client = Select-Client
        Write-host ( 'Выбран клиент ' + $client.Name )

    }
    'N' {
        $client = Get-ClienDetails
    }
}

$kk = Get-String $true 'Хранительский ключ (kk)'

Initialize-Client $client
$torrents_list = Get-Torrents $client '' $false

If ( $torrents_list.Count -eq 0 -or $nul -eq $torrents_list ) {
    Write-Host 'Не удалось получить список раздач, выходим' -ForegroundColor Red
    Exit
}

foreach ( $torrent in $torrents_list ) {
    $trackers = Get-TorrentTrackers $client $torrent.hash | Where-Object { $_.url -match 't-ru\.org/ann\?pk=' }
    $trackers | ForEach-Object {
        Edit-Tracker $client $torrent.hash $_.url ( $_.url -replace ( '\.t-ru.org/ann\?pk=.*', ( '.rutracker.cx/ann?kk=' + $kk ) ) )
    }
}