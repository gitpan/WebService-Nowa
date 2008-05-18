#!/usr/local/bin/perl

use strict;
use YAML;
use WebService::Nowa;
use Data::Dumper;

my $config = YAML::LoadFile(shift(@ARGV) || "config.yaml");
my $nowa = WebService::Nowa->new($config);
# $nowa->update_nanishiteru('ヴ');

my $msgs = $nowa->recent;
warn Dumper($msgs);

my $chans = $nowa->channels;
warn Dumper($chans);

my $point = $nowa->point;
print "$point nowa yen!\n";

my $msgs = $nowa->channel_recent;
warn Dumper($msgs);

# $nowa->add_friend('staff');
# $nowa->delete_friend('staff');

