#!/usr/bin/perl
use strict;
use warnings;
use utf8;
use Encode qw(decode encode);
use IO::Select;

my ($session, $current) = @ARGV;
exit unless ($session // '') =~ /^\$\d+$/ && ($current // '') =~ /^\@\d+$/;
sub capture {
    open my $fh, '-|', @_ or die "$!";
    local $/;
    my $out = <$fh> // '';
    close $fh or die "command failed";
    $out =~ s/\n\z//;
    return $out;
}
my $saved = capture('stty', '-g');
system('stty', 'raw', '-echo') == 0 or exit;
binmode STDOUT, ':encoding(UTF-8)';
$| = 1;
print "\e[?25l\e[?1000h\e[?1006h";
END {
    if (defined $saved) {
        print "\e[0m\e[?1000l\e[?1006l\e[?25h";
        system('stty', $saved);
    }
}
$SIG{INT} = $SIG{TERM} = $SIG{HUP} = sub { exit };
my ($redraw, $page, $selected, $page_size, $last) = (1, undef, 0, 1, 0);
my (@rows, @hits);
$SIG{WINCH} = sub { $redraw = 1 };
sub go {
    my ($action) = @_;
    if ($action eq 'close') { exit; }
    if ($action eq 'new') { system('tmux', 'new-window', '-t', "$session:"); exit; }
    if ($action eq 'previous') { $page-- if $page > 0; $selected = $page * $page_size; }
    elsif ($action eq 'next') { $page++ if $page < $last; $selected = $page * $page_size; }
    elsif ($action =~ /^\@\d+$/) { system('tmux', 'select-window', '-t', "$session:$action"); exit; }
    $redraw = 1;
}
sub draw {
    my ($height, $width) = split / /, capture('stty', 'size');
    $page_size = int(($height - 7) / 4);
    $page_size = 1 if $page_size < 1;
    my $limit = $width - 13;
    $limit = 1 if $limit < 1;
    my $state = '#{?#{m:*waiting*,#{P:#{@agent-state}}},!,#{?#{m:*error*,#{P:#{@agent-state}}},×,#{?#{m:*working*,#{P:#{@agent-state}}},⠋,#{?#{m:*1*,#{P:#{&&:#{==:#{@agent-state},done},#{==:#{@agent-unread},1}}}},✓,·}}}}';
    my $format = '#{window_id}\t#{window_index}\t' . $state . '\t#{=/' . $limit . '/…:window_name}';
    @rows = map { [split /\\t/, $_, 4] }
        split /\n/, decode('UTF-8', capture('tmux', 'list-windows', '-t', $session, '-F', encode('UTF-8', $format)));
    @rows = grep { defined $_->[3] && $_->[0] =~ /^\@\d+$/ } @rows;
    if (!defined $page) {
        for my $i (0 .. $#rows) { $selected = $i if $rows[$i][0] eq $current; }
    }
    $selected = $#rows if $selected > $#rows;
    $selected = 0 if $selected < 0;
    $page = int($selected / $page_size);
    $last = @rows ? int($#rows / $page_size) : 0;
    @hits = ([$width - 7, 1, $width, 3, 'close']);
    my $out = "\e[0m\e[2J\e[H\e[38;5;252m";
    $out .= "\e[2;3HTabs  " . ($page + 1) . '/' . ($last + 1);
    $out .= "\e[1;" . ($width - 7) . "H\e[48;5;238m" . (' ' x 8);
    $out .= "\e[2;" . ($width - 7) . "H  Close ";
    $out .= "\e[3;" . ($width - 7) . "H" . (' ' x 8) . "\e[0m";
    for my $slot (0 .. $page_size - 1) {
        my $i = $page * $page_size + $slot;
        last if $i > $#rows;
        my ($id, $index, $icon, $name) = @{$rows[$i]};
        $name =~ s/[\x00-\x1f\x7f]//g;
        my $y = 4 + $slot * 4;
        my $style = $i == $selected ? "\e[48;5;117m\e[38;5;235m\e[1m" : "\e[48;5;237m\e[38;5;252m";
        $out .= $style;
        for my $line (0 .. 2) { $out .= "\e[" . ($y + $line) . ";3H" . (' ' x ($width - 4)); }
        $out .= "\e[" . ($y + 1) . ";5H$icon  $index: $name\e[0m";
        push @hits, [3, $y, $width - 2, $y + 2, $id];
    }
    my $third = int($width / 3);
    for my $button ([1, $third - 1, '‹ Prev', 'previous', $page > 0],
                    [$third + 1, 2 * $third - 1, '+ New', 'new', 1],
                    [2 * $third + 1, $width, 'Next ›', 'next', $page < $last]) {
        my ($x, $end, $label, $action, $enabled) = @$button;
        my $style = $enabled ? "\e[48;5;238m\e[38;5;252m" : "\e[48;5;235m\e[38;5;242m";
        $out .= $style;
        for my $y ($height - 2 .. $height) { $out .= "\e[$y;${x}H" . (' ' x ($end - $x + 1)); }
        my $text_x = $x + int(($end - $x + 1 - length($label)) / 2);
        $out .= "\e[" . ($height - 1) . ";${text_x}H$label\e[0m";
        push @hits, [$x, $height - 2, $end, $height, $action] if $enabled;
    }
    print $out;
    $redraw = 0;
}
my $input = IO::Select->new(\*STDIN);
my $buffer = '';
while (1) {
    draw() if $redraw;
    unless ($input->can_read(0.1)) {
        exit if $buffer eq "\e";
        next;
    }
    my $count = sysread(STDIN, my $bytes, 256);
    last unless $count;
    $buffer .= $bytes;
    while (length $buffer) {
        if ($buffer =~ s/^\e\[<(\d+);(\d+);(\d+)([Mm])//) {
            my ($button, $x, $y, $kind) = ($1, $2, $3, $4);
            next if $kind eq 'm';
            if ($button == 64 || $button == 65) { go($button == 64 ? 'previous' : 'next'); next; }
            next unless $button == 0;
            for my $hit (@hits) {
                if ($x >= $hit->[0] && $x <= $hit->[2] && $y >= $hit->[1] && $y <= $hit->[3]) { go($hit->[4]); last; }
            }
        } elsif ($buffer =~ s/^\e\[([ABCD])//) {
            my $key = $1;
            if ($key eq 'C' || $key eq 'D') { go($key eq 'C' ? 'next' : 'previous'); }
            else { $selected += $key eq 'B' ? 1 : -1; $redraw = 1; }
        } elsif ($buffer =~ /^\e(?:\[<?[0-9;]*)?$/) { last; }
        else {
            my $key = substr($buffer, 0, 1, '');
            exit if $key eq "\e" || $key eq 'q' || $key eq "\x03";
            go('new') if $key eq 'n';
            go($rows[$selected][0]) if ($key eq "\r" || $key eq "\n") && @rows;
            if ($key eq 'j' || $key eq 'k') { $selected += $key eq 'j' ? 1 : -1; $redraw = 1; }
        }
    }
}
