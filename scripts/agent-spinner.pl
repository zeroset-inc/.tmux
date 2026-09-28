#!/usr/bin/perl
use strict;
use warnings;
use Fcntl qw(:flock);
use Digest::SHA qw(sha256_hex);
use Time::HiRes qw(time sleep);
use POSIX qw(WNOHANG);

my $socket = shift // exit;
umask 0077;
my $path = ($ENV{TMPDIR} // '/tmp/') . '/tmux-spinner-' . $< . '-' . sha256_hex($socket) . '.lock';
open my $lock, '>>', $path or exit;
flock($lock, LOCK_EX | LOCK_NB) or exit;

sub tm {
    open my $fh, '-|', 'tmux', '-S', $socket, @_ or die "tmux: $!";
    local $/;
    my $out = <$fh> // '';
    close $fh or die "tmux exited";
    return $out;
}

my ($check_at, $working) = (0, 0);
my $git_pid;
eval {
    while (-S $socket) {
        my $now = time;
        if ($now >= $check_at) {
            if (!defined $git_pid || waitpid($git_pid, WNOHANG) != 0) {
                $git_pid = fork();
                if (defined $git_pid && !$git_pid) {
                    exec '/usr/bin/perl', "$ENV{HOME}/.config/tmux/ui.pl", 'git-lines', $socket;
                    exit 1;
                }
            }
            my $states = tm('list-panes', '-a', '-F', '#{session_attached} #{@agent-state}');
            $working = $states =~ /^[1-9]\d* working$/m;
            $check_at = $now + 1;
        }
        if ($working) {
            tm('set-option', '-gq', '@agent-frame', int($now * 10) % 10);
            my $tick = time * 10;
            sleep((int($tick) + 1 - $tick) / 10);
        } else {
            sleep 1;
        }
    }
};
