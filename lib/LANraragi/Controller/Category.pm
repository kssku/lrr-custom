package LANraragi::Controller::Category;
use Mojo::Base 'Mojolicious::Controller';

use utf8;
use URI::Escape;
use Redis;
use Encode;
use Mojo::Util qw(xml_escape);

use LANraragi::Model::Archive;
use LANraragi::Model::Tankoubon;
use LANraragi::Utils::Generic qw(generate_themes_header);
use LANraragi::Utils::Redis   qw(redis_decode);

# Go through the archives in the content directory and build the template at the end.
sub index {

    my $self  = shift;
    my $redis = $self->LRR_CONF->get_redis;

    my $userlogged = $self->LRR_CONF->enable_pass == 0 || $self->session('is_logged');

    $redis->quit();

    # CUSTOM FORK (feature/path-hash-id): 不再在服务端预渲染全部归档。
    #
    # 上游这里调用 generate_archive_list() 拿全量归档再拼 <li>。在十万级归档的
    # 库上，这一句耗时可达分钟级，直接撞 Mojolicious prefork 的 50 秒心跳红线
    # （日志里 "has no heartbeat (50 seconds), restarting" 就是这么来的），
    # 而且生成的 HTML 有十几 MB，浏览器也会卡死。
    #
    # 现在归档列表改由前端 category.js 通过 /api/archives?start=N 递归分页拉取
    # （分页已在 Archive.pm 下推到 Redis 的 ZRANGE，单页 ~300ms）。
    # 服务端只保留 tankoubon 列表——它数量少，且没有分页接口。
    #
    # 注意：$arclist 故意留空，模板里 IF arclist 的分支已改为渲染占位符。
    my $arclist = "";

    # Build tank list
    my ( $total, $filtered, @tanks ) = LANraragi::Model::Tankoubon::get_tankoubon_list(-1);
    my $tanklist = "";

    foreach my $tank (@tanks) {
        my $title = xml_escape( %$tank{name} );
        my $id    = xml_escape( %$tank{id} );

        $tanklist .=
          "<li><input type='checkbox' name='archive' id='$id' class='archive' onchange='Category.updateArchiveInCategory(this.id, this.checked)'>";
        $tanklist .= "<label for='$id'> $title</label></li>";
    }

    $self->render(
        template => "category",
        arclist  => $arclist,
        tanklist => $tanklist,
        title    => $self->LRR_CONF->get_htmltitle,
        descstr  => $self->LRR_DESC,
        csshead  => generate_themes_header($self),
        version  => $self->LRR_VERSION
    );
}

1;
