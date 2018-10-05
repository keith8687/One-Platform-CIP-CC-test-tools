#!/usr/bin/env perl
use 5.010;

use strict;
use warnings;

use DBI;
use Digest::MD5 qw(md5_hex);
use Data::Dumper;
use Time::Local;
use Switch;
use File::Path qw(mkpath);
use File::Basename;
use MQClient::MQSeries;
use MQSeries::QueueManager;
use MQSeries::Queue;
use MQSeries::Message;
use List::Util qw(sum);
use test_lib;
use XML::LibXML;

use sigtrap qw/die normal-signals/;

use constant MAX_MSG_SIZE=>(1024*1024*50);
use constant MAX_SUBMISSION_DELAY=>120;
use constant RESPONSE_WAIT_TIME=>600;
use constant PROD_DASHBOARD_CONNECT=>'dbi:Oracle:db1157p.na.mars';
use constant PROD_DASHBOARD_USER=>'dbmaster';
use constant PROD_DASHBOARD_PASSWORD=>'master';

my ($log_folder, $parser);

BEGIN {
	$|=1;
#	binmode STDOUT, ':encoding(UTF8)';
	my $base_folder=dirname($0);
	$log_folder="${base_folder}/log";
	$parser=XML::LibXML->new();
}

my @dqms=(
	{
		QueueManager=>'HUBD20',
		ClientConn=>{ 
			ChannelName=>'IIB_TESTING',
			TransportType=>'TCP',
			ConnectionName=>'hubd20.na.mars(1421)',
			MaxMsgLength=>50*1024*1024
		}
	},
	{
		QueueManager=>'HUBD21',
		ClientConn=>{ 
			ChannelName=>'IIB_TESTING',
			TransportType=>'TCP',
			ConnectionName=>'hubd21.na.mars(1421)',
			MaxMsgLength=>50*1024*1024
		}
	}
);

my %pgws=(
	gwayp3=>{
		login=>'mqm',
		time_correction=>4,
		path_type=>'msg2file'
	},
	gwayp4=>{
		login=>'mqm',
		time_correction=>4,
		path_type=>'msg2file'
	}
);

sub list_gw_msg2file($$) {
	my ($host, $interface)=@_;
	my ($login, $path_type)=($pgws{$host}->{'login'}, $pgws{$host}->{'path_type'});
	my $d=($path_type eq 'msg2file')?
		"/var/opt/apps/ims/prod/msg2file/${interface}*/????????-??????-*-*":
		($path_type eq 'backup')?"/var/opt/apps/dj/prod/backup/${interface}*_m2d_*":'';
	my @result=map
		{
			if ($path_type eq 'msg2file') {
				die "Failed to parse ssh output ${login}\@${host} '$_'"
					unless 4==scalar(my ($folder, $archive, $date, $time)=(m|^.*/msg2file/([^/]*)/((.{8})-(.{6})-[^.]*)[^[:digit:]]*$|));
				(my $queue='QL.OUT.'.$folder)=~s/_/./;
				{datetime=>$date.$time, message_type=>2, identifier=>0, queue=>$queue, host=>$host, path=>$folder.'/'.$archive}
			} elsif ($path_type eq 'backup') {
				die "Failed to parse ssh output ${login}\@${host} '$_'"
					unless 4==scalar(my ($archive, $folder, $date, $time)=(m|^.*/backup/(([^/]*)_m2d_(.{8})_(.{6})_[^.]*)[^[:digit:]]*$|));
        	                (my $queue='QL.OUT.'.$folder)=~s/_/./;
				{datetime=>$date.$time, message_type=>2, identifier=>0, queue=>$queue, host=>$host, path=>$archive}
			}
		}
		split
			"\n",
			`ssh -qn "${login}\@${host}" '
for d in ${d}
do
	[[ -e "\$d" ]] && echo "\$d"
done
			'`;
	print gmtime()." INFO: found ".(scalar @result)." DJ archive(s) in ${login}\@${host}\n";
	return @result;
}

sub list_gw_logs($$) {
	my ($host, $interface)=@_;
	my ($login, $time_correction)=($pgws{$host}->{'login'}, $pgws{$host}->{'time_correction'});
	my @result=map
		{
			die "Failed to parse ssh output ${login}\@${host} '$_'"
				unless 5==scalar(my ($log_file, $date, $time, $queue, $reads)=(m/^(.*_m2d_(.{8})_(.{6})_.*[.]log).* (.*) (.*)$/));
			{datetime=>gm2put_date(put_date2gm($date.$time)+$time_correction*60*60), message_type=>3, identifier=>0, queue=>$queue, host=>$host, path=>$log_file, reads=>$reads}
		}
		split
			"\n",
			`ssh -qn "${login}\@${host}" '
for d in /var/opt/apps/dj/prod/log/${interface}*_m2d_*
do
	if [[ -e "\$d" ]]
	then
		[[ "\$d" == *.gz ]] && cmd=zcat || cmd=cat
		echo "\$(sed -r '"'"'s/^.*[/]([^/]*)\$/\\1/'"'"' <<< "\$d")" "\$("\$cmd" "\$d" | sed -rn '"'"'s/^.*Queue=([^;]*);.*\$/\\1/p'"'"')" "\$("\$cmd" "\$d" | sed -rn '"'"'s/^.*INFO: (.*) message.*read\$/\\1/p'"'"' | tail -1)"
	fi
done
			'`;
	print gmtime()." INFO: found ".(scalar @result)." DJ logs in ${login}\@${host}\n";
	return @result;
}

sub list_gw_outputs($@) {
	my ($host, @archives)=@_;
	my ($login, $path_type)=($pgws{$host}->{'login'}, $pgws{$host}->{'path_type'});
	my $l=join ' ', @archives;
	my $d=($path_type eq 'msg2file')?
		'/var/opt/apps/ims/prod/msg2file/$l':
		($path_type eq 'backup')?'/var/opt/apps/dj/prod/backup/$l':'';
		
	my $x = `ssh -qn "$login"@"$host" '
for l in ${l}
do
	d=${d}
	if [[ -d "\$d" ]]
	then
		for f in "\$d"/*
		do
			if [[ "\$(basename "\$f")" != ~* ]]
			then
				cat "\$f"
			fi
		done
	elif [[ -f "\$d".tar.gz ]]
	then
		d="\$d".tar.gz
		for af in \$(tar -ztvf "\$d" | sed -rn '"'"'s|^.* ('"'"'\$l'"'"'/[^~].*)\$|\\1|p'"'"')
		do
			tar -zxOf "\$d" "\$af"
		done
	elif [[ -f "\$d".data ]]
	then
		cat "\$d".data
	fi
done
		'`;
		
	#print $x."\n";
		
	my @result=split
		"\n",
		`ssh -qn "$login"@"$host" '
for l in ${l}
do
	d=${d}
	if [[ -d "\$d" ]]
	then
		for f in "\$d"/*
		do
			if [[ "\$(basename "\$f")" != ~* ]]
			then
				cat "\$f"
			fi
		done
	elif [[ -f "\$d".tar.gz ]]
	then
		d="\$d".tar.gz
		for af in \$(tar -ztvf "\$d" | sed -rn '"'"'s|^.* ('"'"'\$l'"'"'/[^~].*)\$|\\1|p'"'"')
		do
			tar -zxOf "\$d" "\$af"
		done
	elif [[ -f "\$d".data ]]
	then
		cat "\$d".data
	fi
done
		'`;
	print gmtime()." INFO:  found ".(scalar @result)." line(s) in ".(scalar @archives)." ${login}\@${host} archive(s):\n", Dumper(\@archives);
	return @result;
}

die "$0 interface [max_submission_delay:${\MAX_SUBMISSION_DELAY}] [response_wait_time:${\RESPONSE_WAIT_TIME}] [starting_dashboard_id:0]"
	unless defined $ARGV[0];
my $interface=$ARGV[0]||'';
die "Invalid interface name ${interface}"
	unless $interface=~/[[:upper:]]{6}[[:digit:]]{2}/;
die "Already running for interface ${interface}"
	if `ps -ef | grep -v grep | grep -v $$ | grep perl'.*'\$(basename $0)'.* '${interface}` gt '';
my $max_submission_delay=defined $ARGV[1]?1*('0'.$ARGV[1]):MAX_SUBMISSION_DELAY;
my $response_wait_time=defined $ARGV[2]?1*('0'.$ARGV[2]):RESPONSE_WAIT_TIME;
my $starting_dashboard_id=defined $ARGV[3]?1*('0'.$ARGV[3]):0;
mkpath $log_folder || die "Failed to create ${log_folder}";
my $log_prefix="${log_folder}/${interface}.".gm2put_date(timegm(gmtime())).".${max_submission_delay}_${response_wait_time}_${starting_dashboard_id}.$$";
open(STDOUT, "| tee -ai ${log_prefix}.out.txt") || die "Can not redirect STDOUT";
open(STDERR, "| tee -ai ${log_prefix}.err.txt") || die "Can not redirect STDERR";
print gmtime()." INFO: script name is $0\n";
print gmtime()." INFO: interface name is ${interface}\n";
print gmtime()." INFO: max submission delay is ${max_submission_delay}\n";
print gmtime()." INFO: response wait time is ${response_wait_time}\n";
print gmtime()." INFO: starting dashboard id is ${starting_dashboard_id}\n";

print gmtime()." INFO: Connecting to Prod dashboard DB\n";
my $dh=DBI->connect(
	PROD_DASHBOARD_CONNECT,
	PROD_DASHBOARD_USER,
	PROD_DASHBOARD_PASSWORD,
	{
		ChopBlanks=>1,
		LongReadLen=>MAX_MSG_SIZE
	}
) || die "Can't connect to database";
my $sth=$dh->prepare(
	qq(
SELECT
	hmm.PUT_DATE AS "datetime",
	hmm.MESSAGE_TYPE AS "message_type",
	hmm.IDENTIFIER AS "identifier",
	hmm.QUEUE_NAME AS "queue"
FROM
	HUB_MQSI_MSG hmm,
	HUB_DATA hd_d 
WHERE
	hmm.IDENTIFIER>=:2 AND
	hmm.QUEUE_NAME LIKE '%.'||hmm.INTERFACE_ID||'%' AND
	hmm.TIER=0 AND
	hmm.INTERFACE_ID=:1 AND
	hmm.DATA_IDENTIFIER=hd_d.DATA_IDENTIFIER
	)
) || die "Can't prepare SQL";
$sth->bind_param(1, $interface);
$sth->bind_param(2, $starting_dashboard_id);
$sth->execute() || die "Can't execute SQL";
my $db_rows=$sth->fetchall_arrayref({}, 1_000_000);
unless (scalar @$db_rows) {
	print gmtime()." ERROR: no IN and OUT Id records found in dashboard\n";
	exit 1;
}
print gmtime()." INFO: found ".(scalar @$db_rows)." IN and OUT Id record(s) in dashboard\n";
my @all=map
	{$_->{gm}=put_date2gm($_->{datetime}); $_}
	sort
		{$a->{datetime}<=>$b->{datetime} || $a->{message_type}<=>$b->{message_type} || $a->{identifier}<=>$b->{identifier}}
		(
			@$db_rows,
			map {(list_gw_msg2file($_, $interface), list_gw_logs($_, $interface))} keys %pgws
		);
if ((scalar @$db_rows)==(scalar @all)) {
	print gmtime()." ERROR: no data found in gateways\n";
	exit 1;
}
my $initial_all_count=scalar @all;
while (defined(my $r=shift @all)) {
	if ($r->{message_type}==0) {
		unshift @all, $r;
		last;
	}
}
unless (scalar @all) {
	print gmtime()." ERROR: no matching data found in dashboard and gateways\n";
	exit 1;
}
print gmtime()." INFO: skipped ".($initial_all_count-scalar @all)." DJ archive and log record(s) with no corresponding dashboard records\n";
#my $dqmi=int(rand(2));
my $dqmi=1;
$dqms[$dqmi]{qmh}=MQSeries::QueueManager->new(
	QueueManager=>$dqms[$dqmi]{QueueManager},
	ClientConn=>$dqms[$dqmi]{ClientConn}
) || die "Failed to connect to ".$dqms[$dqmi]{QueueManager};
my $g_submitted=0;
my $m_submitted=0;
my $warnings=0;
while (scalar @all) {
	my $m_submitted_local=0;
	my @grp=();
	my %queues=();
	my $ok=0;
	while (defined(my $r=shift @all)) {
		push @grp, $r;
		(my $q=$r->{queue})=~s/^QA/QL/;
		$q=~s/^QL[.]OUT[.]ATLPLS19[.].*$/QL.OUT.ATLPLS19/;
		$q=~s/^QL[.]OUT[.]ATLPLS20[.].*$/QL.OUT.ATLPLS20/;
		switch ($r->{message_type}) {
			case 0 {}
			case 1 {$queues{$q}{outputs}++}
			case 2 {$queues{$q}{archives}++}
			case 3 {$queues{$q}{logs}++; $queues{$q}{reads}+=$r->{reads}}
		}
		$queues{$q}{ok}=
			(defined $queues{$q}{outputs}) &&
			(defined $queues{$q}{reads}) &&
			(defined $queues{$q}{archives}) &&
			(defined $queues{$q}{logs}) &&
			($queues{$q}{outputs}==$queues{$q}{reads}) &&
			($queues{$q}{archives}==$queues{$q}{logs})
			if defined $queues{$q};
		$ok=
			(scalar keys %queues) &&
			((scalar keys %queues)==(grep {$queues{$_}{ok}} keys %queues));
		last if $ok;
	}
	unless ($ok) {
		print Dumper(\@grp), Dumper(\%queues);
		print gmtime()." ERROR: failed to collect a group\n";
		exit 1;
	}
	print gmtime()." INFO: (".(++$g_submitted).") starting to process group:\n", Dumper(\%queues), Dumper(\@grp);
	my $mh;
	foreach my $oq (keys %queues) {
		print gmtime()." INFO:   cleaning up queue ".$dqms[$dqmi]{QueueManager}.":$oq\n";
		$dqms[$dqmi]{queues}{$oq}=MQSeries::Queue->new(
			QueueManager=>$dqms[$dqmi]{qmh},
			Queue=>$oq,
			Mode=>'input'
		) || die "Cannot open queue ".$dqms[$dqmi]{QueueManager}.":$oq"
			unless defined $dqms[$dqmi]{queues}{$oq};
		my $n=-1;
		do {
			$n++;
		} while ($dqms[$dqmi]{queues}{$oq}->Get(Message=>($mh=MQSeries::Message->new()), Convert=>0, Wait=>'1s')>0);
		print gmtime()." INFO:    $n removed\n";
	}
	my %db_data_rows;
	my @ids=map {$_->{identifier}} grep {$_->{message_type}==0} @grp;
	while (scalar @ids) {
		my @chunk;
		push @chunk, shift @ids
			for (0..($#ids<999?$#ids:999));
		my $sth_data=$dh->prepare(
			qq/
SELECT
	hmm.IDENTIFIER AS "identifier",
	hd_d.DATA AS "data",
	hd_d.DATA_COMPRESSION AS "data_compression"
FROM
	HUB_MQSI_MSG hmm,
	HUB_DATA hd_d 
WHERE
	hmm.IDENTIFIER IN (/.join(', ', @chunk).qq/) AND
	hmm.QUEUE_NAME LIKE '%.'||hmm.INTERFACE_ID||'%' AND
	hmm.TIER=0 AND
	hmm.INTERFACE_ID=:1 AND
	hmm.DATA_IDENTIFIER=hd_d.DATA_IDENTIFIER
			/
		) || die "Can't prepare SQL";
		$sth_data->bind_param(1, $interface);
		$sth_data->execute() || die "Can't execute SQL";
		my $db_data_rows=$sth_data->fetchall_arrayref({}, 1_000_000);
		for (@$db_data_rows) {
			normalize($_->{data}, $_->{data_compression});
			$db_data_rows{$_->{identifier}}=$_->{data};
		}
	}
	unless ((scalar keys %db_data_rows)==sum map {1} grep {$_->{message_type}==0} @grp) {
		print gmtime()." ERROR: invalid amount of IN Data records found in dashboard\n";
		print Dumper keys %db_data_rows;
		exit 1;
	}
	print gmtime()." INFO: found ".(scalar keys %db_data_rows)." IN Data dashboard record(s)\n";
	my $old_put_date=99999999999999;
	foreach my $row (grep {$_->{message_type}==0} @grp) {
		mysleep($row->{gm}-$old_put_date, $max_submission_delay)
			if $old_put_date<$row->{gm};
		$old_put_date=$row->{gm};
		my $iq='QL.IN.'.$interface;
		$dqms[$dqmi]{queues}{$iq}=MQSeries::Queue->new(
			QueueManager=>$dqms[$dqmi]{qmh},
			Queue=>$iq,
			Mode=>'output'
		) || die "Cannot open queue ".$dqms[$dqmi]{QueueManager}.":$iq"
			unless defined $dqms[$dqmi]{queues}{$iq};
		print gmtime()." INFO:  (".(++$m_submitted_local).'/'.(++$m_submitted).") submitting dashboard ID/PUT_DATE ".$row->{identifier}."/".$row->{datetime}." into ".$dqms[$dqmi]{QueueManager}.":".${iq}."\n";
		die "Put failure for queue ".$dqms[$dqmi]{QueueManager}.":${iq}"
			unless $dqms[$dqmi]{queues}{$iq}->Put(Message=>($mh=MQSeries::Message->new(Data=>$db_data_rows{$row->{identifier}}, MsgDesc=>{CodedCharSetId=>1208})));
	}
	foreach my $oq (keys %queues) {
		my @archives=grep
			{$_->{message_type}==2 && $_->{queue} eq $oq}
			@grp;
		my %hosts=map {$_->{host}=>1} @archives;
		my @expected=map
			{my $host=$_; list_gw_outputs($_, map {$_->{path}} grep {$_->{host} eq $host} @archives)}
			keys %hosts;
		print gmtime()." INFO:  it's expected to get totally ".(scalar @expected)." line(s) from queue ".$dqms[$dqmi]{QueueManager}.":".${oq}."\n";
#		my $mh=MQSeries::Message->new(MsgDesc=>{CodedCharSetId=>1208});
		my (@no_match, @data);
		my $outputs=0;
		while ($dqms[$dqmi]{queues}{$oq}->Get(Message=>($mh=MQSeries::Message->new()), Wait=>$response_wait_time.'s', Convert=>0)>0) {
			$outputs++;
			@data=split "\n", $mh->Data();
			print gmtime()." INFO:  got ".(scalar @data)."-line(s) message from ".$dqms[$dqmi]{QueueManager}.":".${oq}."\n";
			while (defined (my $data=shift @data)) {
				my $x=1;
				@expected=grep
					{
						my $r;
						
						my $item=$_; # $item stores DJ outputs from production
						my $temp_data=$data; # $temp_data stores IIB10 outputs from HUBD21
						
						# In case any valid discrepancies have to be skipped, script update needs to be performed here for substitution
						# Please ensure to make the same replacement in both DJ and IIB10 outputs
						
						if ($interface eq 'ATLGDW08') { 
							$item=~s/^"[[:digit:]]{8}"[|]"[[:digit:]]{6}"[|]/"12345678"|"123456"/;
							$temp_data=~s/^"[[:digit:]]{8}"[|]"[[:digit:]]{6}"[|]/"12345678"|"123456"/;
						}
						
						#if ($interface eq 'ATLGDW01') {
						#		my $sub_item = substr($item, 9, 15, "20170101|000000"); # Replacing DJ output with "20170101|000000", from position 10 for 15 digits
						#		my $sub_temp_data = substr($temp_data, 9, 15, "20170101|000000"); # Replacing IIB10 output with "20170101|000000", from position 10 for 15 digits
						#}
						
						if ($interface eq 'ATLIPS01') {
								my $sub_item = substr($item, 116, 10, "2016-01-01"); # Replacing DJ output with "2016-01-01", from position 117 for 10 digits
								my $sub_temp_data = substr($temp_data, 116, 10, "2016-01-01"); # Replacing IIB10 output with "2016-01-01", from position 117 for 10 digits
						}
						if ($interface eq 'ATLRSS02'){
						 my $sub_item = substr($item, 56, 70, "1234567123456712345671234567123456712345671234567123456712345671234567");
						 my $sub_temp_data = substr($temp_data, 56, 70, "1234567123456712345671234567123456712345671234567123456712345671234567");
						}


						if ($interface eq 'ATLRSS08'){
                                                 my $sub_item = substr($item, 108, 40, "123456712345671234567123456712345671234");
                                                 my $sub_temp_data = substr($temp_data, 108, 40, "123456712345671234567123456712345671234");
                                                }
	
						if ($interface eq 'ATLLOD03') {
								
							# Replacement is only required for particualr segments for ATLLOD03
							my $segment_indicator1 = substr($item, 0, 4); # Identifying the segment indicator in DJ output
							my $segment_indicator2 = substr($temp_data, 0, 4); # Identifying the segment indicator in IIB10 output
							
							if ($segment_indicator1 eq "0000"){ # Replacing the last 14 digits on "0000" segment with value of "12345678123456" in DJ output
								$item=~s/[[:digit:]]{14}$/12345678123456/;
							}
							if ($segment_indicator2 eq "0000"){ # Replacing the last 14 digits on "0000" segment with value of "12345678123456" in IIB10 output
								$temp_data=~s/[[:digit:]]{14}$/12345678123456/;
							}
						}
					
						if ($interface eq 'ATLMRM02') {
                                                        my $segment_indicator1 = substr($item, 0, 1);
                                                        my $segment_indicator2 = substr($temp_data, 0, 1);

                                                        if ($segment_indicator1 eq "H"){ 
                                                                 my $sub_item = substr($item, 17, 14, "12345671234567");
                                                        }
                                                        if ($segment_indicator2 eq "H"){ 
                                                                 my $sub_temp_data = substr($temp_data, 17, 14, "12345671234567");
                                                        }
                                                }
						

						if ($interface eq 'ATLWTP03') {
						
								my $segment_indicator1 = substr($item, 0, 1);
								my $segment_indicator2 = substr($temp_data, 0, 1);

								if ($segment_indicator1 eq "H"){
										 my $sub_item = substr($item, 1, 14, "12345671234567");
								}
								
								print "DJ:\n", $item, "\n";
								
								if ($segment_indicator2 eq "H"){
										 my $sub_temp_data = substr($temp_data, 1, 14, "12345671234567");
								}
								
								print "IIB10:\n", $temp_data, "\n";
								
						}


						if ($interface eq 'ATLMRM05') {
								my $segment_indicator1 = substr($item, 0, 1);
								my $segment_indicator2 = substr($temp_data, 0, 1);

								if ($segment_indicator1 eq "H"){ 
										 my $sub_item = substr($item, 18, 14, "12345671234567");
								}
								if ($segment_indicator2 eq "H"){ 
										 my $sub_temp_data = substr($temp_data, 18, 14, "12345671234567");
								}
						}
						
						if ($interface eq 'BIOWWY01') {
								
								my $sub_item = substr($item, 0, 14, "12345671234567");
								my $sub_temp_data = substr($temp_data, 0, 14, "12345671234567");

						}

						if ($interface eq 'ATLMAR90') {
							
							my $segment_indicator1 = substr($item, 0, 3);
							my $segment_indicator2 = substr($temp_data, 0, 3);

							if ($segment_indicator1 eq "TRN"){
							
								my $sub_item = substr($item, 5, 13, "1234567890123");
								$sub_item = substr($item, 25, 14, "12345678901234");
								
							}
							if ($segment_indicator1 eq "SKU"){
							
								my $sub_item = substr($item, 7, 14, "12345671234567");
								
							}
							if ($segment_indicator1 eq "TRL"){
							
								my $sub_item = substr($item, 5, 13, "1234567123456");
								
							}

							if ($segment_indicator2 eq "TRN"){
							
								my $sub_temp_data = substr($temp_data, 5, 13, "1234567890123");
								$sub_temp_data = substr($temp_data, 25, 14, "12345678901234");
								
							}
							
							if ($segment_indicator2 eq "SKU"){
							
								my $sub_temp_data = substr($temp_data, 7, 14, "12345671234567");
								
							}
							if ($segment_indicator2 eq "TRL"){
							
								my $sub_temp_data = substr($temp_data, 5, 13, "1234567123456");
								
							}

						}
						
						
						if ($interface eq 'ATLSKE09') {
							
							my $segment_indicator1 = substr($item, 0, 3);
							my $segment_indicator2 = substr($temp_data, 0, 3);

							if ($segment_indicator1 eq "CRE"){
							
								my $sub_item = substr($item, 7, 14, "12345678901234");								
								
							}						

							if ($segment_indicator2 eq "CRE"){
							
								my $sub_temp_data = substr($temp_data, 7, 14, "12345678901234");
								
							}						
							

						}
						
						if ($interface eq 'ATLMAR91') {
							
							my $segment_indicator1 = substr($item, 0, 3);
							my $segment_indicator2 = substr($temp_data, 0, 3);

							if ($segment_indicator1 eq "TRN"){
							
								my $sub_item = substr($item, 5, 17, "1234567890123");
								   $sub_item = substr($item, 25, 38, "12345678890123");
								
							}
							if ($segment_indicator1 eq "LOT"){
							
								my $sub_item = substr($item, 7, 20, "12345671234567");
								   $sub_item = substr($item, 25, 38, "12345678890123"); 
								   $sub_item = substr($item, 116, 123, "12345678");
								
							}
							if ($segment_indicator1 eq "TRL"){
							
								my $sub_item = substr($item, 5, 17, "1234567890123");
								
							}

							if ($segment_indicator2 eq "TRN"){
							
								my $sub_temp_data = substr($temp_data, 5, 17, "1234567890123");
								   $sub_temp_data = substr($temp_data, 25, 38, "12345678890123");
								
							}
							
							if ($segment_indicator2 eq "LOT"){
							
								my $sub_temp_data = substr($temp_data, 7, 20, "12345671234567");
								   $sub_temp_data = substr($temp_data, 25, 38, "12345678890123");
								   $sub_temp_data = substr($temp_data, 116, 123, "12345678");
							}
							if ($segment_indicator2 eq "TRL"){
							
								my $sub_temp_data = substr($temp_data, 5, 17, "1234567890123");
								
							}

						}
												
						if ($interface eq 'ATLMAR94') {
							
							my $segment_indicator1 = substr($item, 0, 4);
							my $segment_indicator2 = substr($temp_data, 0, 4);

							if ($segment_indicator1 eq "TRNH"){
									 my $sub_item = substr($item, 5, 34, "1234567123456712345671234567123456");
							}
							if ($segment_indicator1 eq "RECL"){
									 my $sub_item = substr($item, 7, 14, "12345671234567");
							}
							if ($segment_indicator1 eq "RECH"){
									 my $sub_item = substr($item, 7, 14, "12345671234567");
							}

							if ($segment_indicator2 eq "TRNH"){
									 my $sub_temp_data = substr($temp_data, 5, 34, "1234567123456712345671234567123456");
							}
							if ($segment_indicator2 eq "RECL"){
									 my $sub_temp_data = substr($temp_data, 7, 14, "12345671234567");
							}
							if ($segment_indicator2 eq "RECH"){
									 my $sub_temp_data = substr($temp_data, 7, 14, "12345671234567");
							}
						}

						if ($interface eq 'ATLMAR95') {
						
								my $segment_indicator1 = substr($item, 0, 4);
								my $segment_indicator2 = substr($temp_data, 0, 4);

								if ($segment_indicator1 eq "TRNH"){
										 my $sub_item = substr($item, 5, 13, "1234567890123");
										 $sub_item = substr($item, 25, 14, "12345678901234");
								}
								if ($segment_indicator1 eq "PORH"){
										 my $sub_item = substr($item, 7, 14, "12345671234567");
								}
								if ($segment_indicator1 eq "PORL"){
										 my $sub_item = substr($item, 7, 14, "12345671234567");
								}
								if ($segment_indicator1 eq "TRLR"){
										 my $sub_item = substr($item, 5, 13, "1234567890123");
								}

								if ($segment_indicator2 eq "TRNH"){
										 my $sub_temp_data = substr($temp_data, 5, 13, "1234567890123");
										 $sub_temp_data = substr($temp_data, 25, 14, "12345678901234");
								}
								if ($segment_indicator2 eq "PORH"){
										 my $sub_temp_data = substr($temp_data, 7, 14, "12345671234567");
								}
								if ($segment_indicator2 eq "PORL"){
										 my $sub_temp_data = substr($temp_data, 7, 14, "12345671234567");
								}
								if ($segment_indicator2 eq "TRLR"){
										 my $sub_temp_data = substr($temp_data, 5, 13, "1234567890123");
								}
								
						}

						if ($interface eq 'ATLGDW01') {

                                                        # Replacement is only required for particualr segments for ATLGDW02
                                                        my $segment_indicator1 = substr($item, 0, 8); # Identifying the segment indicator in DJ output
                                                        my $segment_indicator2 = substr($temp_data, 0, 8); # Identifying the segment indicator in IIB10 output

                                                        if ($segment_indicator1 eq "HDR     "){ 
							# Replacing 15 digits from position 10 on "HDR" segment with value of "20160101|000000" in DJ output
                                                                my $sub_item = substr($item, 9, 15, "20160101|000000");
                                                        }
                                                        elsif ($segment_indicator1 eq "DIM     "){
                                                                my $sub_item = substr($item, 9, 15, "20160101|000000");
                                                        }
                                                        elsif ($segment_indicator1 eq "COND    "){
								my $sub_item = substr($item, 9, 15, "20160101|000000");
                                                        }
                                                        elsif ($segment_indicator1 eq "HDR_COND"){
                                                                my $sub_item = substr($item, 9, 15, "20160101|000000");
                                                        }
							elsif ($segment_indicator1 eq "SUMS "){
                                                                my $sub_item = substr($item, 9, 15, "20160101|000000");
                                                        }
							elsif ($segment_indicator1 eq "POS     "){
                                                                my $sub_item = substr($item, 9, 15, "20160101|000000");
                                                        }

                                                        if ($segment_indicator2 eq "HDR     "){ 
							# Replacing 15 digits from position 10 on "HDR" segment with value of "20160101|000000" in IIB10 output
                                                                my $sub_temp_data = substr($temp_data, 9, 15, "20160101|000000");
                                                        }
                                                        elsif ($segment_indicator2 eq "DIM     "){
                                                                my $sub_temp_data = substr($temp_data, 9, 15, "20160101|000000");
                                                        }
                                                        elsif ($segment_indicator2 eq "COND    "){
                                                                my $sub_temp_data = substr($temp_data, 9, 15, "20160101|000000");
                                                        }
                                                        elsif ($segment_indicator2 eq "HDR_COND"){
                                                                my $sub_temp_data = substr($temp_data, 9, 15, "20160101|000000");
                                                        }	
                                                        elsif ($segment_indicator2 eq "SUMS "){
                                                                my $sub_temp_data = substr($temp_data, 9, 15, "20160101|000000");
                                                        }
							elsif ($segment_indicator2 eq "POS     "){
                                                                my $sub_temp_data = substr($temp_data, 9, 15, "20160101|000000");
                                                        }
                                                }

						if ($interface eq 'ATLGDW05') {
							my $segment_indicator1 = substr($item, 0, 3); # Identifying the segment indicator in DJ output
                                                	my $segment_indicator2 = substr($temp_data, 0, 3); # Identifying the segment indicator in IIB10 output

							if ($segment_indicator1 eq "HDR"){
								 my $sub_item = substr($item, 4, 15, "20160101|000000");
							}
							if ($segment_indicator1 eq "POS"){
                                                                 my $sub_item = substr($item, 4, 15, "20160101|000000");
                                                        }


							if ($segment_indicator2 eq "HDR"){
								 my $sub_temp_data = substr($temp_data, 4, 15, "20160101|000000");
							}
							if ($segment_indicator2 eq "POS"){
                                                                 my $sub_temp_data = substr($temp_data, 4, 15, "20160101|000000");
                                                        }
						}
						
						if ($interface eq 'ATLGDW02') {
						
							# Replacement is only required for particualr segments for ATLGDW02
							my $segment_indicator1 = substr($item, 0, 8); # Identifying the segment indicator in DJ output
							my $segment_indicator2 = substr($temp_data, 0, 8); # Identifying the segment indicator in IIB10 output
							
							if ($segment_indicator1 eq "HDR     "){ # Replacing 15 digits from position 10 on "HDR" segment with value of "20160101|000000" in DJ output
								my $sub_item = substr($item, 9, 15, "20160101|000000");
							}
							elsif ($segment_indicator1 eq "DIM     "){
								my $sub_item = substr($item, 163, 15, "20160101|000000");
							}
							elsif ($segment_indicator1 eq "EAN     "){
										my $sub_item = substr($item, 73, 15, "000000|20160101");
								}
							elsif ($segment_indicator1 eq "E1MARCM "){
										my $sub_item = substr($item, 88, 15, "20160101|000000");
								}
                        
							if ($segment_indicator2 eq "HDR     "){ # Replacing 15 digits from position 10 on "HDR" segment with value of "20160101|000000" in IIB10 output
									my $sub_temp_data = substr($temp_data, 9, 15, "20160101|000000");
							}
								elsif ($segment_indicator2 eq "DIM     "){
										my $sub_temp_data = substr($temp_data, 163, 15, "20160101|000000");
							}
							elsif ($segment_indicator2 eq "EAN     "){
										my $sub_temp_data = substr($temp_data, 73, 15, "000000|20160101");
								}
								elsif ($segment_indicator2 eq "E1MARCM "){
										my $sub_temp_data = substr($temp_data, 88, 15, "20160101|000000");
								}
						}
						
						if ($interface eq 'ATLTPM01') {
						
							# Replacement is only required for H segment for ATLTPM01
							my $segment_indicator1 = substr($item, 0, 1); # Identifying the segment indicator in DJ output
							my $segment_indicator2 = substr($temp_data, 0, 1); # Identifying the segment indicator in IIB10 output
							
							if ($segment_indicator1 eq "H"){ # Replacing idoc number from position 10 on "H" segment with value of "1234567890" in DJ output
								my $sub_item = substr($item, 20, 10, "1234567890");
								$sub_item = substr($item, 181, 28, "2017091812354720170918123547");
							}

							if ($segment_indicator2 eq "H"){ # Replacing idoc number from position 10 on "H" segment with value of "1234567890" in IIB10 output
								my $sub_temp_data = substr($temp_data, 20, 10, "1234567890");
								$sub_temp_data = substr($temp_data, 181, 28, "2017091812354720170918123547");
							}
							
						}
						
						if ($interface eq 'ATLTPM02') {
						
							# Replacement is only required for H segment for ATLTPM01
							my $segment_indicator1 = substr($item, 0, 1); # Identifying the segment indicator in DJ output
							my $segment_indicator2 = substr($temp_data, 0, 1); # Identifying the segment indicator in IIB10 output
							
							if ($segment_indicator1 eq "H"){ # Replacing idoc number from position 10 on "H" segment with value of "1234567890" in DJ output
								my $sub_item = substr($item, 20, 10, "1234567890");
								$sub_item = substr($item, 181, 28, "2017091812354720170918123547");
							}

							if ($segment_indicator2 eq "H"){ # Replacing idoc number from position 10 on "H" segment with value of "1234567890" in IIB10 output
								my $sub_temp_data = substr($temp_data, 20, 10, "1234567890");
								$sub_temp_data = substr($temp_data, 181, 28, "2017091812354720170918123547");
							}
							
						}
						if ($interface eq 'ATLTPM07') {
						
							# Replacement is only required for H segment for ATLTPM07
							my $segment_indicator1 = substr($item, 0, 1); # Identifying the segment indicator in DJ output
							my $segment_indicator2 = substr($temp_data, 0, 1); # Identifying the segment indicator in IIB10 output
							
							if ($segment_indicator1 eq "H"){ # Replacing idoc number from position 10 on "H" segment with value of "1234567890" in DJ output
								my $sub_item = substr($item, 22, 11, "12345678901");
								 $sub_item = substr($item, 188, 21, "201709181235472017091");
							}

							if ($segment_indicator2 eq "H"){ # Replacing idoc number from position 10 on "H" segment with value of "1234567890" in IIB10 output
								my $sub_temp_data = substr($temp_data, 22, 11, "12345678901");
								  $sub_temp_data = substr($temp_data, 188, 15, "201709181235472017091");
							}
							
						}
						if ($interface eq 'ATLDOL08') {

                                                        # Replacement is only required for E1EDKT20001CONSEGNA segment for ATLDOL08
                                                        my $segment_indicator1 = substr($item, 0, 4); # Identifying the segment indicator in DJ output
                                                        my $segment_indicator2 = substr($temp_data, 0, 4); # Identifying the segment indicator in IIB10 output

                                                          if ($segment_indicator1 eq "E1EDK"){ # Replacing from position 40 on "E1EDKT20001CONSEGNA" segment with value of "012345" in DJ output
                                                            my $sub_item = substr($item, 5, 57, "012345678901234567890123456789012345678901234567890123456");
															   #$item=~s/\s*$//g;
                                                        }
                             if ($segment_indicator2 eq "E1EDK"){ # Replacing  number from position 40 on "E1EDKT20001CONSEGNA" segment with value of "012345" in DJ output
                                                                my $sub_item = substr($temp_data, 5, 57, "012345678901234567890123456789012345678901234567890123456");
																#$temp_data=~s/\s*$//g;
                                                        }
                                                }
												
												
												
						if ($interface eq 'ATLGDW03') {
							$item=~s/^"[[:digit:]]*"[,]"[[:digit:]]*"[,]/"12345678","123456",/; # Replacing the first two fields on each record lines in DJ output
							$temp_data=~s/^"[[:digit:]]*"[,]"[[:digit:]]*"[,]/"12345678","123456",/; # Replacing the first two fields on each record lines in IIB10 output
						}
						
						if ($interface eq 'ATLGDW04') {
							$item=~s/^"[[:digit:]]*"[,]"[[:digit:]]*"[,]/"12345678","123456",/;
							$temp_data=~s/^"[[:digit:]]*"[,]"[[:digit:]]*"[,]/"12345678","123456",/;
						}
						
						if ($interface eq 'USMBTB01') {
							$item=~s/<PMNT_INVDATE>[[:digit:]]{10}/<PMNT_INVDATE>2016-01-01/; # Replacing 10 digits in PMNT_INVDATE with value of "2016-01-01" in DJ output
							$item=~s/<PMNT_REFDATE>[[:digit:]]{10}/<PMNT_REFDATE>2016-01-01/; # Replacing 10 digits in PMNT_REFDATE with value of "2016-01-01" in DJ output
							$temp_data=~s/<PMNT_INVDATE>[[:digit:]]{10}/<PMNT_INVDATE>2016-01-01/; # Replacing 10 digits in PMNT_INVDATE with value of "2016-01-01" in IIB10 output
							$temp_data=~s/<PMNT_REFDATE>[[:digit:]]{10}/<PMNT_REFDATE>2016-01-01/; # Replacing 10 digits in PMNT_REFDATE with value of "2016-01-01" in IIB10 output
						}
						
#						if ($interface eq 'ATLFDS01') {
#								$item=~s/^H[;][[:digit:]]*[;]/H;010101020202;/; # Replacing the first field on "H" segment with value of "010101020202" in DJ ouptut
#								$temp_data=~s/^H[;][[:digit:]]*[;]/H;010101020202;/; # Replacing the first field on "H" segment with value of "010101020202" in IIB10 ouptut
#						}
					
						 if ($interface eq 'ATLFDS01') {
                                                        #$item=~s/^H[;][[:digit:]]*[;]/H;010101020202;/;
                                                        #$temp_data=~s/^H[;][[:digit:]]*[;]/H;010101020202;/;
							my $segment_indicator1 = substr($item, 0, 1);
                                                                my $segment_indicator2 = substr($temp_data, 0, 1);


							if ($oq eq 'QL.OUT.ATLFDS01.3') {
#                                                                my $segment_indicator1 = substr($item, 0, 1);
#                                                                my $segment_indicator2 = substr($temp_data, 0, 1);

                                                                if ($segment_indicator1 eq "H"){
                                                                        my $sub_item = substr($item, 2, 12, "123456789000");
                                                                }
                                                                elsif ($segment_indicator1 eq "L"){
                                                                        my $sub_item = substr($item, 104, 8, "12345678");
                                                                }

                                                                if ($segment_indicator2 eq "H"){
                                                                        my $sub_temp_data = substr($temp_data, 2, 12, "123456789000");
                                                                }
                                                                elsif ($segment_indicator2 eq "L"){
                                                                        my $sub_temp_data = substr($temp_data, 104, 8, "12345678");
                                                                }
							} else {

								#my $segment_indicator1 = substr($item, 0, 1);
                                                                #my $segment_indicator2 = substr($temp_data, 0, 1);

                                                                if ($segment_indicator1 eq "H"){
                                                                        my $sub_item = substr($item, 2, 12, "123456789000");
                                                                }
								elsif ($segment_indicator1 eq "L"){
                                                                        my $sub_item = substr($item, 72, 8, "12345678");
                                                                }

								
								if ($segment_indicator2 eq "H"){
                                                                        my $sub_temp_data = substr($temp_data, 2, 12, "123456789000");
                                                                }
								elsif ($segment_indicator2 eq "L"){
                                                                        my $sub_temp_data = substr($temp_data, 72, 8, "12345678");
                                                                }

							
							}  # IF ELSE                                              
						} # IF	
						 if ($interface eq 'ATLFDS03') {
                                                        #$item=~s/^H[;][[:digit:]]*[;]/H;010101020202;/;
                                                        #$temp_data=~s/^H[;][[:digit:]]*[;]/H;010101020202;/;
							      	my $segment_indicator1 = substr($item, 0, 1); 
      								my $segment_indicator2 = substr($temp_data, 0, 1); 

								if ($segment_indicator1 eq "H"){ 
            								my $sub_item = substr($item, 2, 12, "123456789000");
								}		
	  							elsif ($segment_indicator1 eq "L"){
									my $sub_item = substr($item, 72, 8, "12345678");
								}
	 
								if ($segment_indicator2 eq "H"){
									my $sub_temp_data = substr($temp_data, 2, 12, "123456789000");
								}
								elsif ($segment_indicator2 eq "L"){
									my $sub_temp_data = substr($temp_data, 72, 8, "12345678");
								}
                                                }

	
						if ($interface eq 'ATLPLS01') {
							$item=~s/^H[;][[:digit:]]*[;]/H;010101020202;/;
							$temp_data=~s/^H[;][[:digit:]]*[;]/H;010101020202;/;
						}
						
						if ($interface eq 'ATLWTP01') {
								$item=~s/^H[;][[:digit:]]*[;]/H;010101020202;/;
								$temp_data=~s/^H[;][[:digit:]]*[;]/H;010101020202;/;
						}
						
						if ($interface eq 'ATLPIR01') {
								$item=~s/^H[;][[:digit:]]*[;]/H;010101020202;/;
								$temp_data=~s/^H[;][[:digit:]]*[;]/H;010101020202;/;
						}
						
						if ($interface eq 'ATLSMP01') {
							my $segment_indicator1 = substr($item, 0, 8);
							my $segment_indicator2 = substr($temp_data, 0, 8);
							
							if ($segment_indicator1 eq "SMPMATER"){
										my $sub_item = substr($item, 8, 22, "2016010100000000000000");
								}

							if ($segment_indicator2 eq "SMPMATER"){
										my $sub_temp_data = substr($temp_data, 8, 22, "2016010100000000000000");
							   }
						}
						
						if ($interface eq 'ATLGDW06') { 
							$item=~s/^"(...)"[|]"[[:digit:]]{8}"[|]"[[:digit:]]{6}"[|]/"$1"|"12345678"|"123456"/;
							$temp_data=~s/^"(...)"[|]"[[:digit:]]{8}"[|]"[[:digit:]]{6}"[|]/"$1"|"12345678"|"123456"/;
						}
						
						if ($interface eq 'CHRATL01') { 
							$item=~s/\xe3/\xc3\xa3/;
							$item=~s/\xed/\xc3\xad/;
							$item=~s/\xf1/\xc3\xb1/;
							$item=~s/\xa0/\xc2\xa0/;
							$item=~s/\xb7/\xc2\xb7/;
						}
						
						if ($interface eq 'ATLDOL14') {
								my $sub_item = substr($item, 102, 18, "123456789012345678");
								$item=~s/\s*$//g;
								my $sub_temp_data = substr($temp_data, 102, 18, "123456789012345678");
								$temp_data=~s/\s*$//g;
						}
						
						if ($interface eq 'ATLDOL11') {

                                                        # Replacement is only required for E1EDK18Z01 segment for ATLDOL11
                                                        my $segment_indicator1 = substr($item, 0, 9); # Identifying the segment indicator in DJ output
                                                        my $segment_indicator2 = substr($temp_data, 0, 9); # Identifying the segment indicator in IIB10 output

                                                        if ($segment_indicator1 eq "E1EDK18Z01"){ # Replacing from position 40 on "E1EDK18Z01" segment with value of "012345" in DJ output
                                                            my $sub_item = substr($item, 40, 7, "0123456");
                                                        }
                             if ($segment_indicator2 eq "E1EDK18Z01"){ # Replacing  number from position 40 on "E1EDK18Z01" segment with value of "012345" in DJ output
                                                                my $sub_item = substr($temp_data, 40, 7, "0123456");
                                                        }
                                                }	
						
						
						
						if ($interface eq 'ATLDOL18') {

                                                        # Replacement is only required for E1FISEG segment for ATLDOL18
                                                        my $segment_indicator1 = substr($item, 0, 1); # Identifying the segment indicator in DJ output
                                                        my $segment_indicator2 = substr($temp_data, 0, 1); # Identifying the segment indicator in IIB10 output

                                                        if ($segment_indicator1 eq "E1FISEG"){ # Replacing idoc number from position 10 on "E1FISEG" segment with value of "1234567890" in DJ output
                                                                my $sub_item = substr($item, 69, 4, "1234567890");
                                                        }
                             if ($segment_indicator1 eq "E1FISEG"){ # Replacing idoc number from position 10 on "E1FISEG" segment with value of "1234567890" in DJ output
                                                                my $sub_item = substr($temp_data, 69, 4, "1234567890");
                                                        }
                                                }
						
						
						
						
						
						$x=0
							if ($r=($x && ($item eq $temp_data)));
						!$r
					}
					@expected;
				push(@no_match, $data)
					if $x;
			}
			last unless (scalar @expected) && (scalar @expected!=scalar @no_match);
		}
		print gmtime()." INFO:  got nothing else from ".$dqms[$dqmi]{QueueManager}.":".${oq}."\n"
			if scalar @expected;
		if (scalar @expected || scalar @data) {
			print 'no match: ', Dumper(\@no_match);
			print 'remaining expected: ', Dumper(\@expected);
			print gmtime()." ERROR: see failures above\n";
			exit 1;
		}
		print gmtime()." WARNING:  (".(++$warnings).") the number of output messages (${outputs}) differs from the number of archives (".(scalar @archives).")\n"
			if (scalar @archives)!=$outputs;
		print gmtime()." INFO:  validation is successful for ".$dqms[$dqmi]{QueueManager}.":".${oq}." outputs\n";
	}
}
print gmtime()." WARNING: there are ".$warnings." warnings\n";
exit;

END {
	print gmtime()." WARNING: doing cleanup\n";
}

__END__


WMB7 in messages<=WMB7 out messages=reads>=logs=archives<=files
sort 1		sort 2		sort 3
PUT_DATA	WMB7_in=0	IDENTIFIER	queue
PUT_DATA	WMB7_out=1	IDENTIFIER	queue
PUT_DATA	archive=2	0			queue	host	folder/archive	
PUT_DATA	log=3		0			queue	host	log_file		reads

0. skip anything before the first WMB7_in record

1. group until for all queues &
- sum(queue:reads)==count(WMB7_out:queue)
- count(log:queue)==count(archive:queue)

2. extract and send out WMB7_in with delays

3. for each queue:
	GWread and MQGet all, merge, sort, md5




WMB7 in message
WMB7 out message
WMB7 in queue
WMB7 out queue
GW archive(queue)
GW output message(archive)


DJ archive
/var/opt/apps/ims/prod/msg2file/${QUEUE}/*
PUT_DATE:ok GMT, created before Log
/var/opt/apps/ims/prod/msg2file/ATLADM12_2/20160505-132341-isxl1050-14624


Log format
/var/opt/apps/dj/prod/log/${DJ_INTERFACE}_${DJ_NODE}*
PUT_DATE: add 4 hours to get GMT, created after DJ archive
/var/opt/apps/dj/prod/log/ATLADM12_2_m2d_20160505_092341_14641.log.gz
05/05/2016 13:23:41   1      0 O Global                                                           INFO: MQSeries connect string is 'Queue=QL.OUT.ATLADM12.2;Queuemgr=GWAYP4;CCSID=1208;Convert=TRUE;Timeout=30'
05/09/2016 12:43:46   1      0 O Global                                                           New file name is /var/opt/apps/ims/prod/msg2file/ATLFDS01_1/20160509-124346-isxl1050-27436/ATLFDS01.djdata_0000001195625253
05/05/2016 13:24:12   1      0 O Global                                                           INFO: 18 message(_s) read


ATLFDS01.1
each message - new file
/var/opt/apps/dj/prod/log/ATLFDS01.1_1_m2d_20160509_084346_27447.log
05/09/2016 12:43:46   1      0 O Global                                                           New file name is /var/opt/apps/ims/prod/msg2file/ATLFDS01_1/20160509-124346-isxl1050-27436/ATLFDS01.djdata_0000001195625253


ATLADM12.2
all messages into the same file


WMB7-GW(dj)
ls -l /var/opt/apps/ims/prod/msg2file/ATLADM12_2/20160505-132341-isxl1050-14624


WMB8-GW(dj)
ls -l /var/opt/apps/ims/prod/msg2file/ATLXTL02/20160504-171001-isxl1050-11108





#list m2d DJ interfaces
ls /var/opt/apps/dj/prod/log/ | sed -rn 's/^(.{8}).*_m2d_.*$/\1/p' | sort | uniq


#confirm the number of output files per archive
for interface in $(ls /var/opt/apps/dj/prod/log/ | sed -rn 's/^(.{8}).*_m2d_.*$/\1/p' | sort | uniq)
do
 for archive in /var/opt/apps/ims/prod/msg2file/${interface}*/*/
 do
  echo $archive $(ls $archive | grep -v ^~ | wc -l)
 done
done | grep -v ' 1$'
/var/opt/apps/ims/prod/msg2file/ATLFDS01_1/20160509-124346-isxl1050-27436/ 32
/var/opt/apps/dj/prod/log/ATLFDS01.1_1_m2d_20160509_084346_27447.log
05/09/2016 12:43:46   1      0 O Global                                                           New file name is /var/opt/apps/ims/prod/msg2file/ATLFDS01_1/20160509-124346-isxl1050-27436/ATLFDS01.djdata_0000001195625253


