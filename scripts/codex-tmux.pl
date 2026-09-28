#!/usr/bin/perl
use strict;
use warnings;

my $codex = "$ENV{HOME}/.local/bin/codex";
my @args = @ARGV;

my %commands = map { $_ => 1 } qw(agents exec review login logout mcp plugin app-server remote-control app completion update doctor sandbox debug apply queue archive delete migrate-rollouts unarchive cloud exec-server features help);
unless (grep { /^(?:--remote(?:=|$)|--no-daemon$|--help$|--version$)/ || $_ eq '-h' || $_ eq '-V' || $commands{$_} } @args) {
    unshift @args, '--no-daemon';
}
exec $codex, @args;
die "Cannot start codex: $!";
