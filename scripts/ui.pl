#!/usr/bin/perl
use strict;
use warnings;
use utf8;

sub capture {
    my (@args) = @_;
    pipe(my $reader, my $writer) or die "pipe: $!";
    my $pid = fork();
    die "fork: $!" unless defined $pid;
    if (!$pid) {
        close $reader;
        open STDOUT, '>&', $writer or exit 1;
        open STDERR, '>', '/dev/null' or exit 1;
        close $writer;
        exec @args;
        exit 1;
    }
    close $writer;
    my $output;
    my $ok = eval {
        local $SIG{ALRM} = sub { die "timeout\n" };
        alarm 2;
        local $/;
        $output = <$reader> // '';
        waitpid($pid, 0);
        my $status = $?;
        alarm 0;
        die "command failed\n" if $status;
        1;
    };
    alarm 0;
    close $reader;
    unless ($ok) {
        kill 'KILL', $pid;
        waitpid($pid, 0);
        die "command failed\n";
    }
    $output =~ s/\n\z//;
    return $output;
}

my $mode = shift // '';
if ($mode eq 'git-lines') {
    my $socket = shift;
    my @tmux = ('tmux', defined $socket ? ('-S', $socket) : ());
    my %width;
    for (split /\n/, capture(@tmux, 'list-clients', '-F', '#{session_id} #{client_width}')) {
        my ($session, $columns) = split / /;
        next unless defined $columns && $columns =~ /^\d+$/;
        $width{$session} = $columns if !exists $width{$session} || $columns < $width{$session};
    }
    my $rows = capture(@tmux, 'list-sessions', '-F',
                       '#{session_id}\t#{pane_current_path}\t#{status}');
    for my $row (split /\n/, $rows) {
        my ($session, $path, $lines) = split /\\t/, $row, 3;
        next unless defined $lines && $session =~ /^\$\d+$/;
        my $root = eval { capture('git', '-C', $path, 'rev-parse', '--show-toplevel') };
        my $wanted = ($width{$session} // 80) < 80 && defined $root && length $root ? '2' : 'on';
        capture(@tmux, 'set-option', '-t', $session, 'status', $wanted) if $lines ne $wanted;
    }
    exit;
}
if ($mode eq 'tabs') {
    my ($client, $session, $current) = @ARGV;
    exit unless defined $client && ($session // '') =~ /^\$\d+$/ && ($current // '') =~ /^\@\d+$/;
    my $command = '/usr/bin/perl "$HOME/.config/tmux/tab-picker.pl" ' . "'$session' '$current'";
    exec 'tmux', 'display-popup', '-B', '-E', '-c', $client,
         '-x', '0', '-y', '0', '-w', '100%', '-h', '100%', $command;
    die "Could not open tabs picker: $!";
}
if ($mode eq 'menus') {
    my $bindings = capture('tmux', 'list-keys', '-T', 'root');
    my @menus = grep { /MouseDown3/ && /display-menu/ } split /\n/, $bindings;
    for (@menus) { s/\bdisplay-menu\b(?:\s+-[OM]+\b)*/display-menu -O -M/g; }
    my ($pane_menu) = grep { /-T root\s+M-MouseDown3Pane\s/ } @menus;
    if (defined $pane_menu) {
        @menus = grep { !/-T root\s+MouseDown3Pane\s/ } @menus;
        $pane_menu =~ s/(-T root\s+)M-MouseDown3Pane\b/${1}MouseDown3Pane/;
        push @menus, $pane_menu;
    }
    open my $out, '|-', 'tmux', 'source-file', '-' or die "tmux: $!";
    print $out join("\n", @menus), "\n";
    close $out or die "Could not update menu bindings";
    exit;
}
if ($mode eq 'reorder') {
    my ($session, $target) = @ARGV;
    capture('tmux', 'set-option', '-t', $session, '@tab-dragging', '0');
    my $source = capture('tmux', 'show-options', '-qv', '-t', $session, '@drag-window');
    my %index = map { split / /, $_, 2 }
                split /\n/, capture('tmux', 'list-windows', '-t', $session,
                                     '-F', '#{window_id} #{window_index}');
    exit unless defined $index{$source} && defined $index{$target} && $source ne $target;
    my $side = $index{$source} < $index{$target} ? '-a' : '-b';
    capture('tmux', 'move-window', '-d', $side, '-s', "$session:$source", '-t', "$session:$target");
    capture('tmux', 'move-window', '-r', '-t', $session);
    capture('tmux', 'select-window', '-t', "$session:$source");
    exit;
}
if ($mode eq 'new-space') {
    my ($client) = @ARGV;
    my $next = capture('tmux', 'show-options', '-gqv', '@next-space-number') || 0;
    $next = 0 unless $next =~ /^\d+$/;
    for (split /\n/, capture('tmux', 'list-sessions', '-F', '#{session_name}')) {
        $next = $_ + 1 if /^\d+$/ && $_ >= $next;
    }
    my $id = capture('tmux', 'new-session', '-d', '-P', '-F', '#{session_id}', '-s', "$next");
    capture('tmux', 'set-option', '-g', '@next-space-number', $next + 1);
    capture('tmux', 'switch-client', '-c', $client, '-t', $id);
    exit;
}
if ($mode eq 'spaces') {
    my ($client, $current) = @ARGV;
    require Encode;
    my @items = ('+ New space', 'n',
                 q{run-shell -b '/usr/bin/perl "$HOME/.config/tmux/ui.pl" new-space #{q:client_name}'},
                 'Rename current space…', 'r',
                 q{command-prompt -p 'Space name:' { rename-session '%1' }}, '');
    my $rows = capture('tmux', 'list-sessions', '-F',
                       '#{session_id}\t#{session_name}\t#{session_windows}');
    my $key = 1;
    for my $row (split /\n/, $rows) {
        my ($id, $name, $windows) = split /\\t/, $row;
        next unless defined $id && $id =~ /^\$[0-9]+$/;
        $name = Encode::decode('UTF-8', $name);
        $name =~ s/[\x00-\x1f\x7f]//g;
        $name =~ s/#/##/g;
        $name = "space $name" if $name =~ /^\d+$/;
        my $label = ($id eq ($current // '') ? '● ' : '  ') . $name;
        $label .= "  ($windows " . ($windows == 1 ? 'tab)' : 'tabs)');
        push @items, $label, $key <= 9 ? "$key" : '', "switch-client -t '$id'";
        $key++;
    }
    exec 'tmux', 'display-menu', '-O', '-M', '-c', $client, '-T', 'Spaces',
         '-x', '0', '-y', 'S', @items;
    die "Could not open spaces menu: $!";
}
if ($mode eq 'headers') {
    my $windows = capture('tmux', 'list-windows', '-a', '-F',
                          '#{window_id} #{window_panes} #{pane-border-status}');
    my %seen;
    for (split /\n/, $windows) {
        my ($id, $panes, $current) = split / /;
        next if $seen{$id}++;
        my $position = $panes > 1 ? 'top' : 'off';
        next if $current eq $position;
        capture('tmux', 'set-option', '-w', '-t', $id, 'pane-border-status', $position);
    }
    exit;
}
die "usage: ui.pl git PATH | headers\n" unless $mode eq 'git' && @ARGV == 1;
require Encode;
binmode STDOUT, ':encoding(UTF-8)';
my $path = shift;
$ENV{GIT_OPTIONAL_LOCKS} = '0';
sub git { Encode::decode('UTF-8', capture('git', '-C', $path, @_)); }
my $root = eval { git('rev-parse', '--show-toplevel') };
exit if $@;

sub styled {
    my ($text, $color, $bold) = @_;
    $text =~ s/[^[:print:]]//g;
    $text =~ s/#/##/g;
    return '#[fg=' . $color . ($bold ? ',bold' : '') . "]$text#[default]";
}

eval {
    my $status = git('status', '--porcelain=v2', '--branch', '--untracked-files=normal');
    my ($branch, $oid) = ('', '');
    my ($ahead, $behind, $staged, $modified, $untracked, $conflicts) = (0) x 6;
    for (split /\n/, $status) {
        if (/^# branch.head (.*)/) { $branch = $1; }
        elsif (/^# branch.oid (.*)/) { $oid = substr($1, 0, 7); }
        elsif (/^# branch.ab \+(\d+) -(\d+)/) { ($ahead, $behind) = ($1, $2); }
        elsif (/^[12] (\S\S) (\S+)/) {
            my ($xy, $sub) = ($1, $2);
            $staged++ if substr($xy, 0, 1) ne '.';
            $modified++ if substr($xy, 1, 1) ne '.' || ($sub ne 'N...' && $sub ne 'S...');
        }
        elsif (/^\? /) { $untracked++; }
        elsif (/^u /) { $conflicts++; }
    }
    $branch = "detached\@$oid" if $branch eq '(detached)';
    my $worktrees = git('worktree', 'list', '--porcelain');
    my $count = () = $worktrees =~ /^worktree /mg;
    my ($green, $red, $tan) = ('#8bd5ca', '#ed8796', '#eed49f');
    my $name = $root;
    $name =~ s{.*/}{};
    my @parts = (styled($name, '#f4f4f4', 1), styled($branch, $tan));
    for my $item (['↑', $ahead, $green], ['↓', $behind, $red],
                  ['+', $staged, $green], ['!', $modified, $tan],
                  ['?', $untracked, $tan], ['×', $conflicts, $red]) {
        push @parts, styled("$item->[0]$item->[1]", $item->[2]) if $item->[1];
    }
    push @parts, styled('✓', $green) unless $staged || $modified || $untracked || $conflicts;
    push @parts, styled("wt:$count", 'colour245');
    my $dir = git('rev-parse', '--absolute-git-dir');
    for my $item (['rebase-merge', 'REBASE'], ['rebase-apply', 'REBASE'],
                  ['MERGE_HEAD', 'MERGE'], ['CHERRY_PICK_HEAD', 'CHERRY-PICK'],
                  ['REVERT_HEAD', 'REVERT'], ['BISECT_LOG', 'BISECT']) {
        if (-e "$dir/$item->[0]") {
            push @parts, styled($item->[1], $red);
            last;
        }
    }
    print join(' ', @parts), "\n";
    1;
} or print "git: busy\n";
