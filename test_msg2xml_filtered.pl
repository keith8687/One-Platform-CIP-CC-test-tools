#!/usr/bin/env perl
use 5.010;

use strict;
use warnings;

use DBI;
use Digest::MD5 qw(md5_hex);
use Data::Dumper;
use Time::Local;
use File::Path qw(mkpath);
use File::Basename;
use MQClient::MQSeries;
use MQSeries::QueueManager;
use MQSeries::Queue;
use MQSeries::Message;
use Getopt::Long qw(GetOptions);
use test_lib;

use sigtrap qw/die normal-signals/;

use constant MAX_MSG_SIZE=>(1024*1024*8);
use constant MAX_SUBMISSION_DELAY=>120;
use constant RESPONSE_WAIT_TIME=>120;
use constant PROD_DASHBOARD_CONNECT=>'dbi:Oracle:db1157p.na.mars';
use constant PROD_DASHBOARD_USER=>'dbmaster';
use constant PROD_DASHBOARD_PASSWORD=>'master';

my $log_folder;

BEGIN {
	$|=1;
#	binmode STDOUT, ':encoding(UTF8)';
	my $base_folder=dirname($0);
	$log_folder="${base_folder}/log";
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
		login=>'mqm'
	},
	gwayp4=>{
		login=>'mqm'
	}
);

sub list_gw_msg2file($$$$) {
	my ($host, $interface, $archived_directory_pattern, $filter)=@_;
	my ($login)=($pgws{$host}->{'login'});
	print gmtime()." INFO: retrieving data from ${login}\@${host} for ${interface}\n";
	my @result=grep
		{defined $_}
		map
			{
				die "Failed to parse ssh output $_"
					unless 9==scalar(my ($queue, $folder, $date, $time, $host, $file, $md5, $MsgId, $CorrelId)=(m/^(.*) ((.{8})-(.{6})-(.*)-.*) (.*) (.*) (.*) (.*)$/));
				(my $extension=$queue)=~s/^.*[_]([[:digit:]]*)$/$1/;
				(",${filter},"=~m/.*,${extension},.*/)?{datetime=>$date.$time, host=>$host, queue=>$queue, folder=>$folder, file=>$file, md5=>$md5, MsgId=>$MsgId, CorrelId=>$CorrelId}:undef;
			}
			split
				"\n",
				`ssh -qn "${login}\@${host}" '
n=0
for d in /var/opt/apps/ims/prod/msg2file/${interface}*/${archived_directory_pattern}-??????-*-*
do
	if [[ -d "\$d" ]]
	then
		archive=\$(basename "\$d")
		queue=\$(basename \$(dirname "\$d"))
		cat "\$d"/~msg2xml.log | sed -rn '"'"'s/^Got message.*MsgId=(.*), CorrelId=(.*), .*\$/\\1\\n\\2/p; s/^Write message to ..*[/]msg2file[/](.*).\$/\\1/p'"'"' | while read MsgId
		do
			read CorrelId
			read file
			echo \$queue \$archive \$(basename "\$file") \$(xmllint --encode UTF-8 --format \$(dirname \$(dirname \$d))/"\$file" | md5sum | cut -d " " -f 1) \$MsgId \$CorrelId
		done
		let n++
	elif [[ -f "\$d" ]]
	then
		archive=\$(basename "\$d")
		queue=\$(basename \$(dirname "\$d"))
		folder=\$(sed 's/.tar.gz\$//' <<< \$archive)
		tar -zxOf "\$d" "\$queue/\$folder/~msg2xml.log" | sed -rn '"'"'s/^Got message.*MsgId=(.*), CorrelId=(.*), .*\$/\\1\\n\\2/p; s/^Write message to ..*[/]msg2file[/](.*).\$/\\1/p'"'"' | while read MsgId
		do
			read CorrelId
			read file
			echo \$queue \$folder \$(basename "\$file") \$(tar -zxOf "\$d" "\$file" | xmllint --encode UTF-8 --format - | md5sum | cut -d " " -f 1) \$MsgId \$CorrelId
		done
		let n++
	fi
	[[ \$n == *000 ]] && echo \$n processed >&2
done
				'`;
	print gmtime()." INFO: found ".(scalar @result)." XML output files in ${login}\@${host}\n";
	return @result;
}

my $max_submission_delay=MAX_SUBMISSION_DELAY;
my $response_wait_time=RESPONSE_WAIT_TIME;
my $starting_dashboard_id=0;
my $starting_put_date=0;
my $archived_directory_pattern='????????';
my $filter='';

(GetOptions(
	'msd=s'=>\$max_submission_delay,
	'rwt=s'=>\$response_wait_time,
	'sdi=s'=>\$starting_dashboard_id,
	'spd=s'=>\$starting_put_date,
	'adp=s'=>\$archived_directory_pattern,
	'filter=s'=>\$filter,
) && defined $ARGV[0]) || die "Usage: $0 interface [--msd=max_submission_delay:${\MAX_SUBMISSION_DELAY}] [--rwt=response_wait_time:${\RESPONSE_WAIT_TIME}] [--sdi=starting_dashboard_id:0] [--spd=starting_put_date:0] [--adp=archived_directory_pattern:0] [--filter=X1[,X2...]]";

my $interface=$ARGV[0]||'';
die "Invalid interface name ${interface}"
	unless $interface=~/[[:upper:]]{6}[[:digit:]]{2}/;
die "Already running for interface ${interface}"
	if `ps -ef | grep -v grep | grep -v $$ | grep perl'.*'\$(basename $0)'.* '${interface}` gt '';
mkpath $log_folder || die "Failed to create ${log_folder}";
my $log_prefix="${log_folder}/${interface}.".gm2put_date(timegm(gmtime())).".${max_submission_delay}_${response_wait_time}_${starting_dashboard_id}_${starting_put_date}_${filter}.$$";
open(STDOUT, "| tee -ai ${log_prefix}.out.txt") || die "Can not redirect STDOUT";
open(STDERR, "| tee -ai ${log_prefix}.err.txt") || die "Can not redirect STDERR";
print gmtime()." INFO: script name is $0\n";
print gmtime()." INFO: interface name is ${interface}\n";
print gmtime()." INFO: max submission delay is ${max_submission_delay}\n";
print gmtime()." INFO: response wait time is ${response_wait_time}\n";
print gmtime()." INFO: starting dashboard id is ${starting_dashboard_id}\n";
print gmtime()." INFO: starting put date is ${starting_put_date}\n";
print gmtime()." INFO: archived_directory_pattern is ${archived_directory_pattern}\n";
print gmtime()." INFO: filter is '${filter}'\n";

my @all=sort
	{$a->{datetime}<=>$b->{datetime}}
	(map {list_gw_msg2file($_, $interface, $archived_directory_pattern, $filter)} keys %pgws);
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
#my $dqmi=int(rand(2));
my $dqmi=1;
$dqms[$dqmi]{qmh}=MQSeries::QueueManager->new(
	QueueManager=>$dqms[$dqmi]{QueueManager},
	ClientConn=>$dqms[$dqmi]{ClientConn}
) || die "Failed to connect to ".$dqms[$dqmi]{QueueManager};
my ($m_processed, $m_skipped, $g_processed, $g_skipped, $g_submitted, $m_submitted)=(0, 0, 0, 0, 0, 0);
@all=grep {$_->{datetime}>=$starting_put_date} @all;
while (defined((my @grp=shift @all)[0])) {
	my $m_submitted_local=0;
	for (my $i=0; $i<=$#grp; $i++) {
		for (my $j=0; $j<=$#all; $j++) {
			unless (
				({map {($grp[$i]->{$_} eq $all[$j]->{$_})=>1} qw(host queue folder file)}->{''}) &&
				({map {($grp[$i]->{$_} eq $all[$j]->{$_})=>1} qw(MsgId CorrelId)}->{''})
			) {
				push @grp, $all[$j];
				splice @all, $j, 1;
			}
		}
	}
	my %msgs=map {$_->{MsgId}.':'.$_->{CorrelId}=>1} @grp;
	my %oqs=map {$_->{queue}=>1} @grp;
	print gmtime()." INFO: (".(++$g_submitted).") starting to process a group of ".(scalar @grp)."/".(scalar keys %msgs)." message(s)\n", Dumper(\@grp);
	my $mh;
	
	if ($interface eq 'ATLCIS01' || $interface eq 'ATLCIS03' || $interface eq 'ATLCIS04' || $interface eq 'ATLCIS05' || $interface eq 'ATLCIS07' || $interface eq 'ATLCIS08' || $interface eq 'ATLCIS09' || $interface eq 'ATLCIS10') {
		
		foreach my $oq (map {s/_/./; 'QA.OUT.'.$_.'.PWH'} keys %oqs) {
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
			print gmtime()." INFO:    ${n} removed\n";
		}
		
	}
	else {
	
		foreach my $oq (map {s/_/./; 'QA.OUT.'.$_} keys %oqs) {
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
			print gmtime()." INFO:    ${n} removed\n";
		}
	
	}
	
	my $sth=$dh->prepare("
SELECT
	hmm.PUT_DATE,
	hd_d.DATA,
	hd_d.DATA_COMPRESSION,
	hmm.IDENTIFIER
FROM
	HUB_MQSI_MSG hmm,
	HUB_DATA hd_d
WHERE
	hmm.QUEUE_NAME LIKE '%.'||hmm.INTERFACE_ID||'%' AND
	hmm.IDENTIFIER>=:2 AND
	(".join(' OR ', map {my @t=split ':', $_; "(
--hmm.MSG_ID='".$t[0]."' AND 
hmm.CORREL_ID='".$t[1]."')"} keys %msgs).") AND
	hmm.MESSAGE_TYPE=0 AND
	hmm.TIER=0 AND
	hmm.INTERFACE_ID=:1 AND
	hmm.DATA_IDENTIFIER=hd_d.DATA_IDENTIFIER
ORDER BY
	hmm.PUT_DATE,
	hmm.MSG_ID,
	hmm.CORREL_ID
	") || die "Can't prepare SQL";
	$sth->bind_param(1, $interface);
	$sth->bind_param(2, $starting_dashboard_id);
	$sth->execute() || die "Can't execute SQL";
	my @rows=@{$sth->fetchall_arrayref(undef, 2*scalar keys %msgs)};
	
	if (scalar @rows==scalar keys %msgs) {
		print gmtime()." INFO:  found all the required ".(scalar keys %msgs)." message(s) in the dashboard\n";
		my $old_put_date=99999999999999;
		foreach my $row (@rows) {
			mysleep(put_date2gm($row->[0])-put_date2gm($old_put_date), $max_submission_delay)
				if $old_put_date<$row->[0];
			$old_put_date=$row->[0];
			normalize($row->[1], $row->[2]);
			my $iq='QL.IN.'.$interface;
			$dqms[$dqmi]{queues}{$iq}=MQSeries::Queue->new(
				QueueManager=>$dqms[$dqmi]{qmh},
				Queue=>$iq,
				Mode=>'output'
			) || die "Cannot open queue ".$dqms[$dqmi]{QueueManager}.":$iq"
				unless defined $dqms[$dqmi]{queues}{$iq};
			die "Put failure for queue ".$dqms[$dqmi]{QueueManager}.":${iq}"
				unless $dqms[$dqmi]{queues}{$iq}->Put(Message=>($mh=MQSeries::Message->new(Data=>$row->[1], MsgDesc=>{CodedCharSetId=>1208})));
			print gmtime()." INFO:  (".(++$m_submitted_local).'/'.(++$m_submitted).") submitted dashboard ID/PUT_DATE ".$row->[3]."/".$row->[0]." into ".$dqms[$dqmi]{QueueManager}.":".${iq}."\n";
		}
		my %expected=map
			{$_->{host}.':'.$_->{queue}.':'.$_->{folder}.':'.$_->{file}=>$_->{md5}}
			@grp;
	
		if ($interface eq 'ATLCIS01' || $interface eq 'ATLCIS03' || $interface eq 'ATLCIS04' || $interface eq 'ATLCIS05' || $interface eq 'ATLCIS07' || $interface eq 'ATLCIS08' || $interface eq 'ATLCIS09' || $interface eq 'ATLCIS10') {
		
				foreach my $oq (map {s/_/./; 'QA.OUT.'.$_.'.PWH'} keys %oqs) {
								
					while ($dqms[$dqmi]{queues}{$oq}->Get(Message=>($mh=MQSeries::Message->new()), Wait=>$response_wait_time.'s', Convert=>0)>0) {
						
						#write xml content into a temp file
						my $tmp_file='/tmp/chenkei/tmp_'.$interface.'.xml';
						open(my $fh, '>', $tmp_file) or die "Could not open file '$tmp_file'\n";
						print $fh $mh->Data();
						close $fh;
						
						#use xmllint to normalize the xml
						my $iib10_normalized_xml=`xmllint --encode UTF-8 --format /tmp/chenkei/tmp_${interface}.xml --output /tmp/chenkei/tmp_${interface}_formatted.xml &> /dev/null`;
						
						#when the output is in xml format
						if (-e '/tmp/chenkei/tmp_'.$interface.'_formatted.xml') {
						
							#md5 after xml normalization
							my $md5=`md5sum /tmp/chenkei/tmp_${interface}_formatted.xml | cut -d " " -f 1`;
							$md5 =~ s/^\s+//;
							$md5 =~ s/\s+$//;
							
							print gmtime()." INFO:  IIB10 output md5 => ".$md5."\n";
							
							#remove temp files
							system("rm /tmp/chenkei/tmp_".$interface."*.xml");
							
							foreach my $key (keys %expected) {
								
								if ($md5 eq $expected{$key}) {
									delete $expected{$key};
									last;
								}
								
							}
						
						}
				
					}
				}
		}
		else {
			foreach my $oq (map {s/_/./; 'QA.OUT.'.$_} keys %oqs) {
			
				while ($dqms[$dqmi]{queues}{$oq}->Get(Message=>($mh=MQSeries::Message->new()), Wait=>$response_wait_time.'s', Convert=>0)>0) {

					#write xml content into a temp file
					my $tmp_file='/tmp/chenkei/tmp_'.$interface.'.xml';
					open(my $fh, '>', $tmp_file) or die "Could not open file '$tmp_file'\n";
					print $fh $mh->Data();
					close $fh;
					
					#use xmllint to normalize the xml
					my $iib10_normalized_xml=`xmllint --encode UTF-8 --format /tmp/chenkei/tmp_${interface}.xml --output /tmp/chenkei/tmp_${interface}_formatted.xml`;
					
					#md5 after xml normalization
					my $md5=`md5sum /tmp/chenkei/tmp_${interface}_formatted.xml | cut -d " " -f 1`;
					$md5 =~ s/^\s+//;
					$md5 =~ s/\s+$//;
					
					print gmtime()." INFO:  IIB10 output md5 => ".$md5."\n";
					
					#remove temp files
					system("rm /tmp/chenkei/tmp_".$interface."*.xml");
					
					foreach my $key (keys %expected) {
						
						if ($md5 eq $expected{$key}) {
							delete $expected{$key};
							last;
						}
						
					}
			
				}
			}
		}
		
		if (scalar keys %expected) {
			print Dumper(\%expected);
			print gmtime()." ERROR: \%expected is not empty after reading out ".$dqms[$dqmi]{QueueManager}." queues\n";
			exit 1;
		}
		else {
			
			#remove temp files
			#system("rm /tmp/chenkei/tmp_".$interface."*.xml");
					
			print gmtime()." INFO: success\n";

		}
		$m_processed+=scalar @grp;
		$g_processed++;
	} else {
		print gmtime()." INFO:  found only ".(scalar @rows)." out of the required ".(scalar keys %msgs)." message(s) in the dashboard; skipping\n";
		$m_skipped+=scalar @grp;
		$g_skipped++;
	}
	print gmtime()." INFO:   processed ${m_processed}/${g_processed}, skipped ${m_skipped}/${g_processed} message(s)/message group(s)\n"
		unless ($m_processed+$m_skipped)%1000;
}
exit;

END {
	print gmtime()." WARNING: doing cleanup\n";
}

__END__

WMB7-GW(xml)
ls -l /var/opt/apps/ims/prod/msg2file/ATLAST01/20160503-125626-isxl1050-1796

WMB7-GW(dj)
ls -l /var/opt/apps/ims/prod/msg2file/ATLADM12_2/20160505-132341-isxl1050-14624

WMB8-GW(dj)
ls -l /var/opt/apps/ims/prod/msg2file/ATLXTL02/20160504-171001-isxl1050-11108

