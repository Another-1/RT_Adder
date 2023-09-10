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

$client = Select-Client
Initialize-Client $client

$tracker_torrents = @{}
foreach ( $section in $sections ) {
    $section_torrents = Get-SectionTorrents $forum $section -1
    $section_torrents.Keys | Where-Object { $section_torrents[$_][0] -in (0, 2, 3, 8, 10, 11 ) } | ForEach-Object {
        $tracker_torrents[$section_torrents[$_][7]] = @{
            id             = $_
            section        = $section.ToInt32($nul)
            status         = $section_torrents[$_][0]
            name           = $nul
            reg_time       = $section_torrents[$_][2]
            size           = $section_torrents[$_][3]
            seeders        = $section_torrents[$_][1]
            hidden_section = $section_details[$section.toInt32($nul)][3]
            releaser       = $section_torrents[$_][8]
        }
    }
}

$UserTorrents = Get-UserTorrents $forum

try { $have_list = ( Get-Torrents $client '' $false ) }
catch { Write-Host 'Не удалось получить список раздач из клиента'; exit }

Get-TopicIDs $client $have_list

foreach ( $torrent in $have_list) {
    if ( $torrent.topic_id -in $UserTorrents ) {
        Set-Comment $client $torrent $label
    }
}
