#!/usr/bin/perl
use strict;
use warnings;
use JSON::PP qw(decode_json);
use Fcntl qw(:flock);
use Digest::SHA qw(sha256_hex);

my ($socket) = ($ENV{TMUX} // '') =~ /^(.*),\d+,\d+$/;

sub tm {
    my (@args) = @_;
    open my $fh, '-|', 'tmux', (defined $socket ? ('-S', $socket) : ()), @args or die "tmux: $!";
    local $/;
    my $out = <$fh> // '';
    close $fh or die "tmux command failed";
    $out =~ s/\n\z//;
    return $out;
}

sub lock_server {
    umask 0077;
    my $path = ($ENV{TMPDIR} // '/tmp/') . '/tmux-agent-' . $< . '-' . sha256_hex($socket) . '.lock';
    open my $lock, '>>', $path or die "lock: $!";
    flock($lock, LOCK_EX) or die "lock: $!";
    return $lock;
}

sub route_dir {
    my $dir = "$ENV{HOME}/.config/tmux/agent-clients";
    mkdir $dir, 0700 unless -d $dir;
    return $dir;
}
sub route_path {
    my ($pane) = @_;
    return route_dir() . '/' . sha256_hex("$socket/$pane") . '.json';
}
sub read_route {
    my ($path) = @_;
    open my $fh, '<', $path or return;
    local $/;
    my $route = eval { decode_json(<$fh>) };
    return ref($route) eq 'HASH' ? $route : undef;
}
sub codex_route {
    my ($data) = @_;
    my $session = $data->{session_id} // '';
    return unless $session =~ /^[0-9a-f-]{36}$/;
    my @routes;
    for my $path (glob(route_dir() . '/*.json')) {
        my $route = read_route($path) or next;
        unless (-S ($route->{socket} // '')) { unlink $path; next; }
        if (($route->{token} // '') =~ /^(?:bridge|existing)-(\d+)$/ && !kill(0, $1)) {
            unlink $path;
            next;
        }
        push @routes, $route if ($route->{session_id} // '') eq $session;
    }
    return @routes;
}

sub run {
    my ($data, $pane);
    if (@ARGV && $ARGV[0] =~ /^(register|unregister)$/) {
        return unless defined $socket;
        my $lock = lock_server();
        $pane = $ENV{TMUX_PANE} // '';
        return unless $pane =~ /^%\d+$/;
        my $path = route_path($pane);
        if ($ARGV[0] eq 'unregister') {
            my $route = read_route($path) or return;
            return unless ($route->{token} // '') eq ($ARGV[1] // '');
            unlink $path;
            tm('set-option', '-p', '-t', $pane, '@agent-session', '',
               ';', 'set-option', '-p', '-t', $pane, '@agent-state', '',
               ';', 'set-option', '-p', '-t', $pane, '@agent-unread', '0',
               ';', 'set-option', '-p', '-t', $pane, '@agent-client', '');
            return;
        }
        my ($session, $token, $initial) = @ARGV[1,2,3];
        return unless defined $session && $session =~ /^[0-9a-f-]{36}$/ && defined $token;
        $initial = 'idle' unless defined $initial && $initial =~ /^(idle|working|waiting|done|error)$/;
        tm('set-option', '-p', '-t', $pane, '@agent-session', $session,
           ';', 'set-option', '-p', '-t', $pane, '@agent-client', $token,
           ';', 'set-option', '-p', '-t', $pane, '@agent-state', $initial,
           ';', 'set-option', '-p', '-t', $pane, '@agent-unread', '0');
        umask 0077;
        open my $fh, '>', "$path.$$" or die "route: $!";
        print $fh JSON::PP::encode_json({ session_id => $session, socket => $socket, pane => $pane, token => $token });
        close $fh or die "route: $!";
        rename "$path.$$", $path or die "route: $!";
        return;
    }
    unless (@ARGV == 2 && $ARGV[0] eq 'seen') {
        $data = do { local $/; decode_json(<STDIN> // '{}') };
        return unless ref($data) eq 'HASH';
        return if $data->{agent_id};
        $pane = $ENV{TMUX_PANE} // '';
        unless (defined $socket && $pane =~ /^%\d+$/) {
            for my $route (codex_route($data)) {
                $socket = $route->{socket};
                my $target = $route->{pane};
                next unless defined $socket && defined $target && $target =~ /^%\d+$/;
                eval {
                    my $lock = lock_server();
                    my $identity = tm('display-message', '-p', '-t', $target, '#{@agent-session}/#{@agent-client}');
                    update_state($data, $target) if $identity eq "$route->{session_id}/$route->{token}";
                };
            }
            return;
        }
    }
    return unless defined $socket;
    my $lock = lock_server();

    if (@ARGV == 2 && $ARGV[0] eq 'seen') {
        my $window = $ARGV[1];
        return unless $window =~ /^\@\d+$/;
        for my $pane (split /\n/, tm('list-panes', '-t', $window, '-F', '#{pane_id}')) {
            tm('set-option', '-p', '-t', $pane, '@agent-unread', '0');
        }
        return;
    }

    update_state($data, $pane);
}

sub update_state {
    my ($data, $pane) = @_;
    my $event = $data->{hook_event_name} // '';
    my %states = (
        SessionStart => 'idle', SessionEnd => '',
        UserPromptSubmit => 'working', PreToolUse => 'working',
        PostToolUse => 'working', PostToolUseFailure => 'working',
        PermissionRequest => 'waiting', Stop => 'done',
        StopFailure => 'error', Interrupt => 'idle',
    );
    my $state = $states{$event};
    if ($event eq 'PreToolUse' && ($data->{tool_name} // '') =~ /(?:AskUserQuestion|request_user_input(?:_async)?)$/) {
        $state = 'waiting';
    }
    return unless defined $state;
    return if $event eq 'SessionStart' && ($data->{source} // '') eq 'compact';
    my $session = $data->{session_id} // '';
    return if ref($session);
    my $owner = tm('show-options', '-pqv', '-t', $pane, '@agent-session');
    return if defined $ENV{TMUX_PANE} && $event ne 'SessionStart' && $event ne 'UserPromptSubmit' && $owner ne '' && $owner ne $session;
    my $window = tm('display-message', '-p', '-t', $pane, '#{window_id}');
    my %visible = map { $_ => 1 } split /\n/, tm('list-clients', '-F', '#{window_id}');
    my $unread = $state =~ /^(done|waiting|error)$/ && !$visible{$window} ? '1' : '0';
    tm('set-option', '-p', '-t', $pane, '@agent-session', $session,
       ';', 'set-option', '-p', '-t', $pane, '@agent-state', $state,
       ';', 'set-option', '-p', '-t', $pane, '@agent-unread', $unread);
}

my $ok = eval {
    local $SIG{ALRM} = sub { die "timeout\n" };
    alarm 2;
    run();
    alarm 0;
    1;
};
exit(!$ok && @ARGV && $ARGV[0] eq 'register' ? 1 : 0);
