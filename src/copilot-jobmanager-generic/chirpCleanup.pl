#!/usr/bin/perl 

use strict;
use Redis;
use Data::Dumper;

my $DIR="/opt/Chirp";
my $REDIS_HOST = 'localhost';
my $REDIS_PORT = '6379';
my $JOB_DB="waiting_jobs";
my $RACE_SLEEP = 1800;
my $tree = {};
my $d;
my $numDir = 0;
my $numJob = 0;

foreach $d (split ("\n", `ls $DIR`))
{
    $tree->{$d} = 1;
    ++$numDir;
}

my $redis = Redis->new(server => $REDIS_HOST.":". $REDIS_PORT);

#print Dumper $redis->lrange ($JOB_DB, 0, -1), "\n";
#exit;

foreach $d ( @{$redis->lrange ($JOB_DB, 0, -1)})
{
    delete $tree->{$d} if defined ($tree->{$d});
    ++$numJob;
}

sleep $RACE_SLEEP; 

foreach $d (keys %$tree)
{
    print "$d\n";
    my $toDelete = `rm -rf $DIR/$d`;
    #print "$toDelete\n"

}

print "NumDir: $numDir numJob: $numJob\n";



