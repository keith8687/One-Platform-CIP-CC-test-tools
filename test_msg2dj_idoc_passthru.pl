#!/usr/bin/env perl
use 5.010;

use strict;
#use warnings;

use DBI;
use Digest::MD5 qw(md5_hex);
use Data::Dumper;
use Time::Local;
use Time::Piece;
#use Switch;
use File::Path qw(mkpath);
use File::Basename;
use MQClient::MQSeries;
use MQSeries::QueueManager;
use MQSeries::Queue;
use MQSeries::Message;
use List::Util qw(sum);
use test_lib;
use XML::LibXML;
use Getopt::Long qw(GetOptions);

use sigtrap qw/die normal-signals/;

use constant MAX_MSG_SIZE=>(1024*1024*50);
use constant MAX_SUBMISSION_DELAY=>120;
use constant RESPONSE_WAIT_TIME=>120;
use constant ROOT_TAG=>'DUMMY';
use constant PROD_DASHBOARD_CONNECT=>'dbi:Oracle:db1157p.na.mars';
use constant PROD_DASHBOARD_USER=>'dbmaster';
use constant PROD_DASHBOARD_PASSWORD=>'master';

my ($log_folder, $parser);

BEGIN {

	$|=1;
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

##################################################
# List out idoc# from DJ output
##################################################
sub list_dj_idoc($) {

	my ($filename)=@_;
		
	my @result=split "\n", `grep DOCNUM ${filename} | cut -d">" -f2 | cut -d"<" -f1 | sed 's/^000000//'`;
			
	return @result;
	
}

##################################################
# Collect input reference
##################################################
sub list_input_ref($) {

	my ($interface)=@_;
	
	print gmtime()." INFO: Collecting input from dashboard database\n";

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
				HUB_IDOC.IDOC_NUMBER,
				HUB_IDOC_IF_XRF.IDENTIFIER,
				HUB_IDOC.DATA_IDENTIFIER,
				HUB_IDOC.DATE_PROCESSED,
				HUB_IDOC.DELETE_DATE
			FROM
				HUB_IDOC LEFT JOIN HUB_IDOC_IF_XRF ON HUB_IDOC.IDENTIFIER = HUB_IDOC_IF_XRF.IDENTIFIER
			WHERE
				(HUB_IDOC_IF_XRF.INTERFACE_ID = :1 OR HUB_IDOC_IF_XRF.INTERFACE_ID = 'ATLGDW02' OR HUB_IDOC_IF_XRF.INTERFACE_ID = 'ATLFDS05' OR HUB_IDOC_IF_XRF.INTERFACE_ID = 'FRABTB11'  ) AND
				HUB_IDOC.TIER = 0
		)
	) || die "Can't prepare SQL";
	
	$sth->bind_param(1, $interface);

	$sth->execute() || die "Can't execute SQL";

	my $db_rows=$sth->fetchall_arrayref({}, 1_000_000);
	
	unless (scalar @$db_rows) {
	
		print gmtime()." ERROR: no input found in dashboard\n";
		exit 1;
		
	}

	print gmtime()." INFO: Collected ".(scalar @$db_rows)." dashboard ID(s)\n";
	
	return $db_rows;

}

##################################################
# Collect output reference
##################################################
sub list_output_ref($) {

	my ($interface)=@_;

	print gmtime()." INFO: Collecting output from GWAYP3\n";
	
	my @result_gwayp3=split
		"\n",
		`ssh "mqm\@azr-eus2l1061.mars-ad.net" -q '
		echo "\$(grep "'"<DOCNUM>"'" /var/opt/apps/ims/prod/msg2file/${interface}/*/${interface}* 2> /dev/null  )"
		'`;
		
	print gmtime()." INFO: Collected ".(scalar @result_gwayp3)." DJ archive(s) from GWAYP3\n";

	print gmtime()." INFO: Collecting output from GWAYP4\n";

	my @result_gwayp4=split
		"\n",
		`ssh "mqm\@gwayp4.na.mars" -q '
		echo "\$(grep "'"<DOCNUM>"'" /var/opt/apps/ims/prod/msg2file/${interface}/*/${interface}* 2> /dev/null  )"
			'`;
			
	print gmtime()." INFO: Collected ".(scalar @result_gwayp4)." DJ archive(s) from GWAYP4\n";
	
	my @result;
	push @result, @result_gwayp3;
	push @result, @result_gwayp4;
	
	return @result;

}

##################################################
# Calculate gateway output md5
##################################################
sub gw_md5($$$) {

	my ($interface, $filename, $gway)=@_;
	
	my $data;
	
	$data=`ssh "mqm\@${gway}" -q '
		echo "\$(cat ${filename})"
		'`;

	#-----To skip particular DJ content in validation-----
	if ($interface eq "ATLXTL02") {
		
		$data=~s/ BEGIN="1"//g;
		$data=~s/ SEGMENT="1"//g;
		$data=~s/<SORTL>[^<]*</<SORTL></g;
		
	}
	if ($interface eq "ATLXTL03") {
		
		$data=~s/ BEGIN="1"//g;
		$data=~s/ SEGMENT="1"//g;
		$data=~s/<SPRAS>[^<]*</<SPRAS></g;
		$data=~s/<TDLINE>[^<]*</<TDLINE></g;
		$data=~s/<MAKTX>[^<]*</<MAKTX></g;
		$data=~s/<HERKR>[^<]*</<HERKR></g;
		$data=~s/<TEXT1>[^<]*</<TEXT1></g;

	}
	if ($interface eq "ATLXTL04") {
		
		$data=~s/ BEGIN="1"//g;
		$data=~s/ SEGMENT="1"//g;
		
	}
	#-----To skip particular DJ content in validation-----
	
	# Clear all DJ temp files for the submitted interface
	#my $tmp_linux_command=`rm /tmp/chenkei/tmp*${interface}*DJ*`;
	#sleep(10);

	my $tmp_file='/tmp/chenkei/tmp_'.$interface.'_DJ.xml';
	open(my $fh, '>', $tmp_file) or die "Could not open file '$tmp_file'\n";
	print $fh $data;
	close $fh;
	
	sleep(10);
	
	my $tmp_file1='/tmp/chenkei/tmp_formated_'.$interface.'_DJ.xml';
	
	my $tmp_result=`xmllint --encode UTF-8 --format ${tmp_file} --output ${tmp_file1}`;
	my $result=`md5sum ${tmp_file1} | cut -f1 -d" "`;
	
	return $result;
	
}

##################################################
# Match out input and output & create test script
##################################################
sub test_script(@@) {

	my ($input, @output) = @_;
	my %idoc2file;
	my %idoc2identifier;
	my %identifier2file;
	my $output_count;
	my $input_count;
	
	# Create input hash from idoc number to data identifier
	for ($input_count=0; $input_count < (scalar @$input); $input_count++) {
    
		my $temp_idoc1 = %{@{$input}[$input_count]}->{IDOC_NUMBER};
		my $temp_id = %{@{$input}[$input_count]}->{IDENTIFIER};
		my $temp_data_id = %{@{$input}[$input_count]}->{DATA_IDENTIFIER};
		my $temp_processed_date = %{@{$input}[$input_count]}->{DATE_PROCESSED};
		my $temp_delete_date = %{@{$input}[$input_count]}->{DELETE_DATE};

		#$idoc2identifier{$temp_idoc1} = $temp_data_id;
		$idoc2identifier{$temp_idoc1} = $temp_id;

	}

	#print "Input:\n";
	#print Dumper(\%idoc2identifier);
	
	# Create output hash from idoc number to filename
	for ($output_count=0; $output_count < scalar @output; $output_count++) {
		
		my $temp_output_row = $output[$output_count];
		my @temp_output_array = split(' ', $temp_output_row);
		
		#my $temp_filename = @temp_output_array->[0];
		my $temp_filename = $temp_output_array[0];
		$temp_filename =~ s/://;
		
		#my $temp_idoc2 = @temp_output_array->[1];
		my $temp_idoc2 = $temp_output_array[1];
		$temp_idoc2 =~ s/<DOCNUM>//;
		$temp_idoc2 =~ s/<\/DOCNUM>//;
		$temp_idoc2 =~ s/^[0]*//;

		$idoc2file{$temp_idoc2} = $temp_filename;
    
	}

	#print "Output:\n";
	#print Dumper(\%idoc2file);
	
	# Create test script hash from data identifier to filename
	for (keys %idoc2file){
	
		my $filename = $idoc2file{$_};
		my $o_idoc = $_;
		
		for (keys %idoc2identifier) {
			
			my $identifier = $idoc2identifier{$_};
			my $i_idoc = $_;
			
			if ($o_idoc eq $i_idoc) {
				$identifier2file{$identifier} = $filename;
				last;
			}
		
		}
    
	}
	
	my $rows_id = 0;
	my @file2identifier;

	#print "Test array:\n";

	for (keys %identifier2file) {

		$file2identifier[$rows_id][0] = $identifier2file{$_};
		$file2identifier[$rows_id][1] = $_;
		$rows_id++;
		
	}
	
	#print Dumper(\@file2identifier);
	
	#print "Test array:\n";
		
	my @sorted_file2identifier = sort { $a->[0] cmp $b->[0] } @file2identifier;
	
	#print Dumper(\@sorted_file2identifier);
	
	return @sorted_file2identifier;
	
}

##################################################
# Prepare test parameter
##################################################

#my $max_submission_delay=MAX_SUBMISSION_DELAY;
my $response_wait_time=RESPONSE_WAIT_TIME;
my $xml_root_tag;

(GetOptions(
#	'msd=s'=>\$max_submission_delay,
	'rwt=s'=>\$response_wait_time,
	'xrt=s'=>\$xml_root_tag,
) && defined $ARGV[0]) || die "Usage: $0 interface [--rwt=response_wait_time:120] [--xrt=xml_root_tag:NULL]";
#) && defined $ARGV[0]) || die "Usage: $0 interface [--msd=max_submission_delay:120] [--rwt=response_wait_time:120] [--xrt=xml_root_tag:NULL]";

#die "$0 interface [max_submission_delay:${\MAX_SUBMISSION_DELAY}] [response_wait_time:${\RESPONSE_WAIT_TIME}]"
#	unless defined $ARGV[0];

my $interface=$ARGV[0]||'';

die "Invalid interface name ${interface}"
	unless $interface=~/[[:upper:]]{6}[[:digit:]]{2}/;
	
die "Already running for interface ${interface}"
	if `ps -ef | grep -v grep | grep -v $$ | grep perl'.*'\$(basename $0)'.* '${interface}` gt '';

mkpath $log_folder || die "Failed to create ${log_folder}";

my $current_date = localtime->strftime('%Y%m%d%H%M%S');

#my $log_prefix="${log_folder}/${interface}.".gm2put_date(timegm(gmtime())).".${response_wait_time}_${xml_root_tag}.$$";
my $log_prefix="${log_folder}/${interface}.".$current_date.".${response_wait_time}_${xml_root_tag}.$$";

open(STDOUT, "| tee -ai ${log_prefix}.out.txt") || die "Can not redirect STDOUT";
open(STDERR, "| tee -ai ${log_prefix}.err.txt") || die "Can not redirect STDERR";

print gmtime()." INFO: script name is $0\n";
print gmtime()." INFO: interface name is ${interface}\n";
#print gmtime()." INFO: max submission delay is ${max_submission_delay}\n";
print gmtime()." INFO: response wait time is ${response_wait_time}\n";
print gmtime()." INFO: root tag is ${xml_root_tag}\n";

my $db_rows = list_input_ref($interface);

my @gw_rows = list_output_ref($interface);

my @test_rows = test_script($db_rows, @gw_rows);

my $test_row_id = 0;
my $temp_idoc_count = 0;
my @idoc_array; 
my $test_count = 1;

#Connect to qmgr of HUBD21, where $dqmi=1
my $dqmi=1;
my $qmgr_obj=MQSeries::QueueManager->new(
	QueueManager=>$dqms[$dqmi]{QueueManager},
	ClientConn=>$dqms[$dqmi]{ClientConn}
) || die "Failed to connect to ".$dqms[$dqmi]{QueueManager};

my $test_id=0;

foreach (@test_rows) {
	
	if ($temp_idoc_count == 0) {
		
		$temp_idoc_count++;
		push @idoc_array, $test_rows[$test_row_id][1];
		
	}
	
	if ($test_rows[$test_row_id][0] eq $test_rows[$test_row_id+1][0]) {
	
		$temp_idoc_count++;
		push @idoc_array, $test_rows[$test_row_id+1][1];
	
	}
	else {
		#print "Test ", $test_count++, "\n";
		#print Dumper(\@idoc_array);
			
		my $imh;
		my $omh;
		
		my %db_data_rows;

		# Collect input data from Dashboard DB
		my $dh=DBI->connect(
			PROD_DASHBOARD_CONNECT,
			PROD_DASHBOARD_USER,
			PROD_DASHBOARD_PASSWORD,
			{
				ChopBlanks=>1,
				LongReadLen=>MAX_MSG_SIZE
			}
		) || die "Can't connect to database";

		my $sth_data=$dh->prepare(
		qq/
		SELECT
			HUB_IDOC.IDENTIFIER,
			HUB_IDOC.IDOC_NUMBER,
			HUB_DATA.DATA,
			HUB_DATA.DATA_COMPRESSION,
			HUB_DATA.DATE_CREATED, 
			HUB_IDOC.DATE_PROCESSED
		FROM
			HUB_IDOC,
			HUB_DATA
		WHERE
			HUB_IDOC.IDENTIFIER IN (/.join(', ', @idoc_array).qq/) AND
			HUB_IDOC.DATA_IDENTIFIER = HUB_DATA.DATA_IDENTIFIER AND
			HUB_IDOC.TIER=0
			ORDER BY HUB_IDOC.IDENTIFIER ASC
		/
		) || die "Can't prepare SQL";
		
		$sth_data->execute() || die "Can't execute SQL";
		
		my $db_data_rows=$sth_data->fetchall_arrayref({}, 1_000_000);
		
		my @data_file;
		my $input_count = 0;
		
		for (@$db_data_rows) {
			
			normalize($_->{DATA}, $_->{DATA_COMPRESSION});
			$data_file[$input_count]=$_->{DATA};
			$input_count++;
		}
		
		# Calculate DJ output MD5, and create temp DJ output on local server @ /tmp/chenkei
		my $gway;
		
		if ($test_rows[$test_row_id][0]=~/eus2l1061/) {
			$gway = 'azr-eus2l1061.mars-ad.net';		
		}
		else {
			$gway = 'gwayp4.na.mars';
		}
		
		my $output_dj_md5=gw_md5($interface, $test_rows[$test_row_id][0], $gway);

		my @idoc_sequence=list_dj_idoc('/tmp/chenkei/tmp_formated_'.$interface.'_DJ.xml');

		# Verify if number of idocs found in DJ output is match with dashboard IDs
		if (scalar @$db_data_rows == scalar @idoc_sequence) {
			
			$test_id++;
			
			print gmtime()." INFO: (".$test_id.") processing archive ".$test_rows[$test_row_id][0].":\n";

			# Put input to QL.IN.<Interface>
			
			my $iq=MQSeries::Queue->new(
					QueueManager=>$qmgr_obj,
					Queue=>'QL.IN.'.$interface,
					Mode=>'output'
				) || die "Cannot open queue ".'QL.IN.'.$interface;
			
			#$iq->Set( InhibitGet => 1 );
			
			#my $imh;
			for (my $i = 0; $i < $temp_idoc_count; $i++) {

				print gmtime()." INFO:  (".($i+1).'/'.($temp_idoc_count).") submitting DASHBOARD ID/IDOC NUMBER ".%{@{$db_data_rows}[$i]}->{IDENTIFIER}."/".%{@{$db_data_rows}[$i]}->{IDOC_NUMBER}."\n";

				die "Unable to put message onto queue.\n"
					unless $iq->Put(Message=>($imh=MQSeries::Message->new(Data =>%{@{$db_data_rows}[$i]}->{DATA}, MsgDesc=>{CodedCharSetId=>1208})));
								
				#$imh->Data("");
			}
			
			#$iq->Set( InhibitGet => 0 );
			
			# Get output from QL.OUT.<Interface>
			
			my $oq=MQSeries::Queue->new(
				QueueManager=>$qmgr_obj,
				Queue=>'QL.OUT.'.$interface,
				Mode=>'input'
			) || die "Cannot open queue ".'QL.OUT.'.$interface;
			
			my $data;	
			#my $omh;
			
			while ($oq->Get(Message=>($omh=MQSeries::Message->new()), Wait=>$response_wait_time.'s', Convert=>0)>0) {
									
				$data = $omh->Data();
								
				#$omh->Data("");

			}
			
			#-----To skip particular IIB10 content in validation-----
			if ($interface eq "ATLXTL02") {
            
				$data=~s/<SORTL>[^<]*</<SORTL></g;
            
			}
			
			if ($interface eq "ATLXTL03") {
				
				$data=~s/<SPRAS>[^<]*</<SPRAS></g;
				$data=~s/<TDLINE>[^<]*</<TDLINE></g;
				$data=~s/<MAKTX>[^<]*</<MAKTX></g;
				$data=~s/<HERKR>[^<]*</<HERKR></g;
				$data=~s/<TEXT1>[^<]*</<TEXT1></g;

			}
			
			#-----To skip particular IIB10 content in validation-----
			
			# Clear all IIB10 temp files for the submitted interface
			#my $tmp_linux_command=`rm /tmp/chenkei/tmp*${interface}*IIB10*`;
			#sleep(10);

			# Reconstruct IIB10 output with DJ idoc# sequence
			my $tmp_file='/tmp/chenkei/tmp_'.$interface.'_IIB10.xml';
			open(my $fh, '>', $tmp_file) or die "Could not open file '$tmp_file'\n";
			print $fh $data;
			close $fh;
			
			my $tmp_file1='/tmp/chenkei/tmp_formated_'.$interface.'_IIB10.xml';
			my $tmp_file2='/tmp/chenkei/tmp_reconstructed_'.$interface.'_IIB10.xml';

			sleep(10);

			my $iib10_normalized_1st_xml=`xmllint --encode UTF-8 --format ${tmp_file} --output ${tmp_file1}`;
			
			#my @idoc_sequence=list_dj_idoc($tmp_file1);
			
			#my @root_tag_sequence=split "\n", `grep '<Z_CUSTOMER_HIERARCHY>' ${tmp_file1} -n | cut -f1 -d":"`;
			my @root_tag_sequence=split "\n", `grep '<${xml_root_tag}>' ${tmp_file1} -n | cut -f1 -d":"`;

			my $tmp_reconstructed_IIB10_output;
			
			$tmp_reconstructed_IIB10_output=`head -2 ${tmp_file1} > ${tmp_file2}`;
			
			foreach my $idoc (@idoc_sequence) {
				
				# grep idoc# within IIB10 output
				my $idoc_number_row=`grep ${idoc} ${tmp_file1} -n | cut -f1 -d":"`;
					
				# look for corresponding root tag line numbers
				
				my $start_tag_row;
				my $end_tag_row;
				
				for (my $i=0; $i < scalar @root_tag_sequence; $i++) {
					
					if ($i == (scalar @root_tag_sequence) - 1) {
						$start_tag_row = $root_tag_sequence[$i];
						$end_tag_row = `cat ${tmp_file1} | wc -l`;
						$end_tag_row = $end_tag_row - 1;
					}
					else {
					
						if ($idoc_number_row > $root_tag_sequence[$i] && $idoc_number_row < $root_tag_sequence[$i+1]) {
							$start_tag_row = $root_tag_sequence[$i];
							$end_tag_row = $root_tag_sequence[$i+1] - 1;
							last;
						}
						
					}
				}
				
				# write to a new temp file
				
				$tmp_reconstructed_IIB10_output=`sed -n -e ${start_tag_row},${end_tag_row}p ${tmp_file1} >> ${tmp_file2}`;
			}
			
			$tmp_reconstructed_IIB10_output=`tail -1 ${tmp_file1} >> ${tmp_file2}`;
			
			#print $fh1 $tmp_reconstructed_IIB10_output;
			#close $fh1;
			
			my $tmp_file3='/tmp/chenkei/tmp_final_'.$interface.'_IIB10.xml';

			my $iib10_normalized_2nd_xml=`xmllint --encode UTF-8 --format ${tmp_file2} --output ${tmp_file3}`;

			# Calculate IIB10 output MD5
			
			my $output_IIB10_md5=`md5sum ${tmp_file3} | cut -d " " -f 1`;
			
			$output_IIB10_md5 =~ s/^\s+//;
			$output_IIB10_md5 =~ s/\s+$//;
			$output_dj_md5 =~ s/^\s+//;
			$output_dj_md5 =~ s/\s+$//;
			
			# Print out test result

			print gmtime()." INFO: DJ md5 ".$output_dj_md5."\n";
			print gmtime()." INFO: IIB10 md5 ".$output_IIB10_md5."\n";

			# Compare IIB10 and DJ output
			
			if ($output_IIB10_md5 ne $output_dj_md5) {

				print gmtime()." ERROR: Mismatch found between DJ and IIB10 output:\n";

				#my $dj_file=$test_rows[$test_row_id][0];
				
				my $tmp_linux_command;
				$tmp_linux_command=`mv /tmp/chenkei/tmp_formated_${interface}_DJ.xml /tmp/chenkei/${interface}_DJ.xml`;
				$tmp_linux_command=`mv /tmp/chenkei/tmp_final_${interface}_IIB10.xml /tmp/chenkei/${interface}_IIB10.xml`;

				my $error_msg=`diff /tmp/chenkei/${interface}_DJ.xml /tmp/chenkei/${interface}_IIB10.xml`;
				
				print Dumper($error_msg);
				
				sleep(10);

				#$tmp_linux_command=`rm /tmp/chenkei/tmp*${interface}*`;

				last;	
			
			}
			else {
			
				print gmtime()." INFO: success\n";

			}
			
		}
		else {
			
			print gmtime()." INFO: skipped archive ".$test_rows[$test_row_id][0]." with dashboard ID mismatch (".@$db_data_rows."/".scalar @idoc_sequence.")\n";

		}
		
		$temp_idoc_count=0;
		@idoc_array=();
		@data_file=();
		@idoc_sequence=();
		#$imh->Data("");
		#$omh->Data("");
	}
	
	$test_row_id++;

}
