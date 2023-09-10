Write-Output 'Подгружаем функции'
. "$PSScriptRoot\_functions.ps1"
. "$PSScriptRoot\_settings.ps1"

Write-Output 'Читаем настройки Web-TLO'

$ini_path = $tlo_path + '\data\config.ini'
$ini_data = Get-IniContent $ini_path

$clients = Get-Clients

Write-Host 'Получаем из TLO данные о пользователе'
$forum = @{}
Set-ForumDetails $forum
Write-Output ( 'ID пользователя определён как ' + $forum.UserID )

Write-Output 'Достаём из TLO данные о разделах'
$sections = $ini_data.sections.subsections.split( ',' )
$section_details = @{}
$sections | ForEach-Object {
    $section_details[$_.ToInt32( $nul ) ] = @($ini_data[ $_ ].client, $ini_data[ $_ ].'data-folder', $ini_data[ $_ ].'data-sub-folder', $ini_data[ $_ ].'hide-topics', $ini_data[ $_ ].'label', $ini_data[$_].'control-peers' )
}

if ( $forum.ProxyURL -and $forum.ProxyPassword -and $forum.ProxyPassword -ne '') {
    $proxyPass = ConvertTo-SecureString $ini_data.proxy.password -AsPlainText -Force
    $proxyCred = New-Object System.Management.Automation.PSCredential -ArgumentList $forum.ProxyLogin, $proxyPass
}

$label = Get-String $true 'Укажите метку'

$tracker_torrents = @{}
foreach ( $section in $sections ) {
    $section_torrents = Get-SectionTorrents $forum $section -1
    $section_torrents.Keys | ForEach-Object {
        $tracker_torrents[$section_torrents[$_][7]] = @{
            id             = $_
        }
    }
}

$clients_torrents = @()
foreach ($clientkey in $clients.Keys ) {
    $client = $clients[ $clientkey ]
    Initialize-Client( $client )
    $client_torrents = Get-Torrents $client '' $false $nul $clientkey
    Get-TopicIDs $client $client_torrents
    $clients_torrents += $client_torrents
}

$UserTorrents = Get-UserTorrents $forum

foreach ( $torrent in $clients_torrents) {
    if ( $torrent.topic_id -in $UserTorrents ) {
        Set-Comment $clients[$torrent.client_key] $torrent $label
    }
}
