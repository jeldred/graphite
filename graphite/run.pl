#!/usr/bin/env perl

use strict;
use warnings;

use AnyEvent;
use AnyEvent::Graphite;
use DateTime;
use GSCApp;

use strict;
use warnings;


our $dbh;
our $graphite;

init();
start_daemon();
cleanup();


sub init {
    $dbh = db_connect();
    $graphite = AnyEvent::Graphite->new(host => '10.0.3.64', port => '2003');
    return 1;
}


sub start_daemon {
    my $exit_program = AnyEvent->signal(signal => "INT", cb => sub { cleanup(); exit 1 });
    my $done = AnyEvent->condvar;
    my $every_day    = AnyEvent->timer(interval => 86400, cb => \&every_day   );
    my $every_hour   = AnyEvent->timer(interval => 3600,  cb => \&every_hour  );
    my $every_minute = AnyEvent->timer(interval => 60,    cb => \&every_minute);
    $done->recv;
}


sub graphite_send {
    my $metric = shift;
    my ($name, $value, $timestamp) = main->$metric;
    print join("\t", $name, $value, $timestamp) . "\n";
    return $graphite->send($name, $value, $timestamp);
}


sub db_connect {
    App->init;
    $dbh = App::DB->dbh;
    die "Failed to connect to the database!\n" unless $dbh;
    return $dbh;
}


sub cleanup {
    $dbh->rollback if ($dbh);
    $dbh->disconnect if ($dbh);
    $graphite->finish if ($graphite);
}

sub parse_sqlrun_count {
    my $sql = shift;
    my $output = qx{sqlrun --instance=warehouse "$sql" | head -n 3 | tail -n 1};
    my ($value) = $output =~ /^(\d+)/;
    return $value;
}

###################
#### Every Day ####
###################

sub every_day {
    graphite_send('builds_daily_failed');
    graphite_send('builds_daily_succeeded');
    graphite_send('builds_daily_unstartable');
    return 1;
}

sub builds_prior_daily_status {
    my $status = shift;

    my $datetime = DateTime->now(time_zone => 'America/Chicago');
    my $timeshift = DateTime::Duration->new(days => 1, hours => $datetime->hour, minutes => $datetime->minute, seconds => $datetime->second);
    $datetime -= $timeshift; # Looking at the last complete day

    my $name = join('.', 'new', 'builds', 'daily_' . lc($status));
    my $timestamp = $datetime->strftime("%s");

    my $date_completed = $datetime->strftime('%F');
    my @builds = Genome::Model::Build->get(
        run_by => 'apipe-builder',
        status => $status,
        'date_completed like' => "$date_completed %",
    );
    my $value = scalar @builds;

    return ($name, $value, $timestamp);
}
sub builds_daily_failed {
    return builds_prior_daily_status('Failed');
}
sub builds_daily_succeeded {
    return builds_prior_daily_status('Succeeded');
}
sub builds_daily_unstartable {
    return builds_prior_daily_status('Unstartable');
}

####################
#### Every Hour ####
####################

sub every_hour {
    graphite_send('builds_hourly_failed');
    graphite_send('builds_hourly_succeeded');
    graphite_send('builds_hourly_unstartable');
    return 1;
}

sub builds_prior_hour_status {
    my $status = shift;

    my $datetime = DateTime->now(time_zone => 'America/Chicago');
    my $timeshift = DateTime::Duration->new(hours => 1, minutes => $datetime->minute, seconds => $datetime->second);
    $datetime -= $timeshift; # Looking at the last complete hour

    my $name = join('.', 'new', 'builds', 'hourly_' . lc($status));
    my $timestamp = $datetime->strftime("%s");

    my $date_completed = $datetime->strftime('%F %H:');
    my @builds = Genome::Model::Build->get(
        run_by => 'apipe-builder',
        status => $status,
        'date_completed like' => "$date_completed%",
    );
    my $value = scalar @builds;

    return ($name, $value, $timestamp);
}
sub builds_hourly_failed {
    return builds_prior_hour_status('Failed');
}
sub builds_hourly_succeeded {
    return builds_prior_hour_status('Succeeded');
}
sub builds_hourly_unstartable {
    return builds_prior_hour_status('Unstartable');
}

######################
#### Every Minute ####
######################

sub every_minute {
    graphite_send('builds_current_failed');
    graphite_send('builds_current_running');
    graphite_send('builds_current_scheduled');
    graphite_send('builds_current_succeeded');
    graphite_send('builds_current_unstartable');
    graphite_send('lsf_workflow_run');
    graphite_send('lsf_workflow_pend');
    graphite_send('lsf_alignment_run');
    graphite_send('lsf_alignment_pend');
    graphite_send('lsf_blades_run');
    graphite_send('lsf_blades_pend');
    graphite_send('models_build_requested');
    graphite_send('models_build_requested_first_build');
    graphite_send('models_buildless');
    graphite_send('models_failed');
    return 1;
}

sub builds_current_status {
    my $status = shift;
    my $name = join('.', 'new', 'builds', 'current_' . lc($status));
    my $timestamp = DateTime->now->strftime("%s");
    my $value = parse_sqlrun_count("select count(distinct(gm.genome_model_id)) from mg.genome_model gm where exists (select * from mg.genome_model_build gmb where gmb.model_id = gm.genome_model_id and exists (select * from mg.genome_model_event gme where gme.event_type = 'genome model build' and gme.build_id = gmb.build_id and gme.event_status = '$status' and gme.user_name = 'apipe-builder'))");
    return ($name, $value, $timestamp);
}
sub builds_current_failed {
    return builds_current_status('Failed');
}
sub builds_current_running {
    return builds_current_status('Running');
}
sub builds_current_scheduled {
    return builds_current_status('Scheduled');
}
sub builds_current_succeeded {
    return builds_current_status('Succeeded');
}
sub builds_current_unstartable {
    return builds_current_status('Unstartable');
}

sub lsf_queue_status {
    my ($queue, $status) = @_;
    my $name = join('.', 'new', 'lsf', $queue, lc($status));
    my $timestamp = DateTime->now->strftime("%s");
    my $bjobs_output = qx(bjobs -u apipe-builder -q $queue 2> /dev/null | grep ^[0-9] | grep $status | wc -l);
    my ($value) = $bjobs_output =~ /^(\d+)/;
    return ($name, $value, $timestamp);
}
sub lsf_workflow_run {
    return lsf_queue_status('workflow', 'RUN');
}
sub lsf_workflow_pend {
    return lsf_queue_status('workflow', 'PEND');
}
sub lsf_alignment_run {
    return lsf_queue_status('alignment-pd', 'RUN');
}
sub lsf_alignment_pend {
    return lsf_queue_status('alignment-pd', 'PEND');
}
sub lsf_blades_status {
    my $status = shift;
    my ($long_name, $long_value, $long_timestamp) = lsf_queue_status('long', $status);
    my ($apipe_name, $apipe_value, $apipe_timestamp) = lsf_queue_status('apipe', $status);
    (my $name = $long_name) =~ s/long/blades/g;
    my $timestamp = $long_timestamp;
    my $value = $long_value + $apipe_value;
    return ($name, $value, $timestamp);
}
sub lsf_blades_run {
    return lsf_blades_status('RUN');
}
sub lsf_blades_pend {
    return lsf_blades_status('PEND');
}

sub models_build_requested {
    my $name = join('.', 'new', 'models', 'build_requested');
    my $timestamp = DateTime->now->strftime("%s");
    my $value = parse_sqlrun_count("select count(*) from mg.genome_model gm where gm.build_requested = 1");
    return ($name, $value, $timestamp);
}
sub models_build_requested_first_build {
    my $name = join('.', 'new', 'models', 'build_requested_first_build');
    my $timestamp = DateTime->now->strftime("%s");
    my $value = parse_sqlrun_count("select count(*) from mg.genome_model gm where gm.build_requested = 1 and not exists (select * from mg.genome_model_build gmb where gmb.model_id = gm.genome_model_id)");
    return ($name, $value, $timestamp);
}
sub models_buildless {
    my $name = join('.', 'new', 'models', 'buildless');
    my $timestamp = DateTime->now->strftime("%s");
    my $value = parse_sqlrun_count("select count(*) from mg.genome_model gm where gm.build_requested != 1 and gm.user_name = 'apipe-builder' and not exists (select * from mg.genome_model_build gmb where gmb.model_id = gm.genome_model_id)");
    return ($name, $value, $timestamp);
}
sub models_failed {
    my $name = join('.', 'new', 'models', 'failed');
    my $timestamp = DateTime->now->strftime("%s");
    my $value = parse_sqlrun_count("select count(distinct(gm.genome_model_id)) from mg.genome_model gm where exists (select * from mg.genome_model_build gmb where gmb.model_id = gm.genome_model_id and exists (select * from mg.genome_model_event gme where gme.event_type = 'genome model build' and gme.build_id = gmb.build_id and gme.event_status = 'Failed' and gme.user_name = 'apipe-builder'))");
    return ($name, $value, $timestamp);
}
