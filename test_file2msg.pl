#!/usr/bin/env perl
use 5.010;

use strict;
use warnings;

use DBI;
use Digest::MD5 qw(md5_hex);
use File::Path qw(mkpath rmtree);
use File::Copy;
use File::Basename;
use Data::Dumper;
use Time::Local;
use MQClient::MQSeries;
use MQSeries::QueueManager;
use MQSeries::Queue;
use MQSeries::Message;
use test_lib;
use XML::LibXML; #http://search.cpan.org/~pajas/XML-LibXML-1.69/LibXML.pod

use sigtrap qw/die normal-signals/;

use constant MAX_MSG_SIZE=>(1024*1024*8);
use constant GWAYP_LOGIN=>'mqm';
use constant GWAYP_HOST=>'MTOL1168';
use constant GWAYD_LOGIN=>'mqfts';
use constant GWAYD_HOST=>'gwayd3';
use constant GWAYD_MQFT_CONFIG=>'/opt/apps/ims/maestro/config/mqft_sched_GWAYD3.config';
use constant GWAYD_NAME=>'GWAYD3';
use constant PROD_DASHBOARD_CONNECT=>'dbi:Oracle:db1157p.na.mars';
use constant PROD_DASHBOARD_USER=>'dbmaster';
use constant PROD_DASHBOARD_PASSWORD=>'master';

my ($temp_folder, $cache_folder, $log_folder, $parser);

BEGIN {
	$|=1;
 #	binmode STDOUT, ':encoding(UTF8)';
	my $base_folder=dirname($0);
	my $script_folder=
		$base_folder.
		 '/.'.
		(basename($0, ('.pl'))=~m/^test_(.*)$/)[0];
	$temp_folder="${script_folder}/temp";
	$cache_folder="${script_folder}/cache";
	$log_folder="${base_folder}/log";
#	require XML::LibXML;
	$parser=XML::LibXML->new();
}

my @dqms=(
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

sub read_config($$$) {
	my ($login, $host, $file)=@_;
	return
		map
			{
				s/[[:space:]]{2,}/ /g;
				s/[[:space:]]*=[[:space:]]*/=/;
				s/ $//;
				s/^ //;
				$_
			}
			split
				/\n/,
				`ssh -qn "${login}\@${host}" 'sed '"'"'s/[#].*\$//; /^[[:space:]]*\$/d; :x; /[+][[:space:]]*\$/ { N; s/[+][[:space:]]*\\n/ /; tx }'"'"' ${file}'`;
}

sub read_interface_mqft_config($$$$) {
	my ($interface, $login, $host, $config)=@_;
	my @interface_mqft_config=grep(
		/=.*-(out|)queue Q[AL].IN.${interface}[^.]/,
		read_config($login, $host, $config)
	);
	unless (scalar @interface_mqft_config) {
		print gmtime()." ERROR:   ", $#interface_mqft_config+1, " interface ${interface} configuration(s) found in ${host}:${config}\n";
		exit 1;
	}
	print gmtime()." INFO:  interface ${interface} configuration is found in ${host}:${config}\n";
	return $interface_mqft_config[0];
}

sub cache_identifiers($$$) {
	my ($dh, $interface, $to_cache)=@_;
	return
		unless @$to_cache;
	my $sth=$dh->prepare("
SELECT
	hmm.IDENTIFIER,
	hmm.PUT_DATE,
	hmm.QUEUE_NAME,
	hd_dh.DATA,
	hd_dh.DATA_COMPRESSION,
	hd_d.DATA,
	hd_d.DATA_COMPRESSION
FROM
	HUB_MQSI_MSG hmm,
	HUB_DATA hd_dh,
	HUB_DATA hd_d
WHERE
	hmm.IDENTIFIER in (".join(',', @$to_cache).") AND
	hmm.DATA_HEADER_IDENTIFIER=hd_dh.DATA_IDENTIFIER AND
	hmm.DATA_IDENTIFIER=hd_d.DATA_IDENTIFIER AND
	hmm.MESSAGE_TYPE=1 AND
	hmm.TIER=0 AND
	hmm.INTERFACE_ID=:1
ORDER BY hmm.IDENTIFIER
	") || die "Can't prepare SQL";
	$sth->bind_param(1, $interface);
	$sth->execute() || die "Can't execute SQL";
	my (
		$IDENTIFIER,
		$PUT_DATE,
		$QUEUE_NAME,
		$HEADER,
		$HEADER_COMPRESSION,
		$DATA,
		$DATA_COMPRESSION
	);
	$sth->bind_columns(undef, \$IDENTIFIER, \$PUT_DATE, \$QUEUE_NAME, \$HEADER, \$HEADER_COMPRESSION, \$DATA, \$DATA_COMPRESSION);
	while ($sth->fetch) {
			
		normalize($HEADER, $HEADER_COMPRESSION);
		normalize($DATA, $DATA_COMPRESSION);
		
		# Retrieve the host server for the input files
		die "No <file2xml_host> tag for IDENTIFIER ", $IDENTIFIER
			unless 1==scalar(my ($file2xml_host)=($HEADER=~m|^.*<file2xml_host>(.*)</file2xml_host>.*$|));
			
		# Retrieve the input filename path and filename
		die "No <file2xml_input_file> tag for IDENTIFIER ", $IDENTIFIER
			unless 1==scalar(my ($file2xml_input_file)=($HEADER=~m|^.*<file2xml_input_file>(.*)</file2xml_input_file>.*$|));
		
		# Replacing "/" with "#" as $file2xml_input_file will be used as the cache filename
		($file2xml_input_file)=~s/\//#/g;
		
		open my $fh, '>>', "${cache_folder}/${interface}/${file2xml_host}.${file2xml_input_file}";
		
		# Message content will be parsed into XML format, with namespace included
		my $xml_tree=$parser->parse_string($DATA); 
		my $data=$xml_tree->toString;
		
		# In case any valid discrepancies have to be skipped, script update needs to be performed here for substitution in WMB7 outputs
		
		$data=~s|<CREDAT>[[:digit:]]{8}</CREDAT>|<CREDAT>XCREDATX</CREDAT>|g; # Replacing 8 digits within CREDAT xml tag as "XCREDATX" in WMB7 output
		$data=~s|<CRETIM>[[:digit:]]{6}</CRETIM>|<CRETIM>CRETIM</CRETIM>|g;
		
		if ($interface eq 'AZPATL01') {
		
			$data=~s|<SERIAL>[[:digit:]]*</SERIAL>|<SERIAL>SERIAL</SERIAL>|g; # Replacing any digits within SERIAL xml tag as "SERIAL" in WMB7 output
			$data=~s|<SERIALIZATIONCNT>[[:digit:]]*</SERIALIZATIONCNT>|<SERIALIZATIONCNT>SERIALIZATIONCNT</SERIALIZATIONCNT>|g;
		
		}
		
		if ($interface eq 'ASUATL08') {
		
			$data=~s|<SERIAL>[[:digit:]]*</SERIAL>|<SERIAL>SERIALXXXXXXXX</SERIAL>|g;
			$data=~s|<SERIALIZATIONCNT>[[:digit:]]*</SERIALIZATIONCNT>|<SERIALIZATIONCNT>SERIALXXXXXXXX</SERIALIZATIONCNT>|g;
			$data=~s|<DELETE/>||g;
			#		$data=~s|<DELETE></DELETE>||g;
			#		$data=~s|</DELETE>||g;

		}
				
		if ($interface eq 'WARATL01'){
		
			$data=~s|<CHAR_VALUE></CHAR_VALUE>||g;
			$data=~s|<CHAR_VALUE/>||g;
			
			print "WMB7:\n", $data, "\n";
			
		}

		if ($interface eq 'PLSATL02'){
                        $data=~s|<CHAR_VALUE></CHAR_VALUE>||g;
                        $data=~s|<CHAR_VALUE/>||g;
                }

		 if ($interface eq 'MESATL01'){

			$data=~s|<CHAR_VALUE></CHAR_VALUE>||g;
			$data=~s|<CHAR_VALUE/>||g;

		}
		
		if ($interface eq 'MESATL02'){

			$data=~s|\n||g;
			$data=~s|>(\s)*<|><|g;
			#$data=~s| encoding=\"utf-8\"||g;
			
			#print "WMB7:\n", $file2xml_input_file, "\n", $data, "\n";
		}

		
		if ($interface eq 'CISATL02') {
			$data=~s|<ZEXIDV/><ZQMSTAT/>||g; # Removing empty xml tag of ZEXIDV & ZQMSTAT in WMB7 output
		}
		
		if ($interface eq 'ASUTRI01') {
		
			$data=~s|<VERSION/>||g;
			$data=~s|<VERSION></VERSION>||g;
			$data=~s|<VERSION> </VERSION>||g;
			$data=~s|<FIRMING_IND/>||g;
			$data=~s|<FIRMING_IND></FIRMING_IND>||g;
			$data=~s|<FIRMING_IND> </FIRMING_IND>||g;
			$data=~s|<FIXED_VEND/>||g;
			$data=~s|<FIXED_VEND></FIXED_VEND>||g;
			$data=~s|<FIXED_VEND> </FIXED_VEND>||g;
			
		}
		
		# changes by uppuram
		if ($interface eq 'PRMATL04') {
			$data=~s|<BUDAT>[[:digit:]]{8}</BUDAT>|<BUDAT>XCREDATX</BUDAT>|g; 
			$data=~s|<USNAM></USNAM>||g;
			$data=~s|<USNAM>      </USNAM>||g;
		}  
		
		if ($interface eq 'MERATL01') {
		
			 $data=~s|<PSTNG_DATE>[[:digit:]]{8}</PSTNG_DATE>|<PSTNG_DATE>01234567</PSTNG_DATE>|g;
			 $data=~s|<REF_KEY_1/>||g;
			 $data=~s|<REF_KEY_1></REF_KEY_1>||g;
			 $data=~s|<REF_KEY_2/>||g;
			 $data=~s|<REF_KEY_2></REF_KEY_2>||g;	
			 $data=~s|<REF_KEY_3/>||g;
			 $data=~s|<REF_KEY_3></REF_KEY_3>||g;
			 
		}
		
		if ($interface eq 'DGLPAN05') {
		
			$data=~s|<SPEC_STOCK></SPEC_STOCK>||g; 
			$data=~s|<SPEC_STOCK> </SPEC_STOCK>||g;
			$data=~s|<SPEC_STOCK>||g;
			$data=~s|</SPEC_STOCK>||g;
			
		}
	
		if ($interface eq 'HPSGBR01') {	
		
			$data=~s|<REF_DOC_NO></REF_DOC_NO>||g;
			$data=~s|<REF_DOC_NO/>||g;
			$data=~s|<ALLOC_NMBR></ALLOC_NMBR>||g;
			$data=~s|<ALLOC_NMBR/>||g;
			
		}
		
		if ($interface eq 'QITATL10') {
		
			$data=~s|<CHARG/>||g;
			$data=~s|<INSMK/>||g;							
			$data=~s|<SOBKZ/>||g;
			$data=~s|<RSNUM/>||g;
			$data=~s|<RSPOS/>||g;
			$data=~s|<KZEAR/>||g;
			$data=~s|<RSHKZ/>||g;
			
		}
		
		if ($interface eq 'MARATL90') {
		
			$data=~s|<BLDAT>[[:digit:]]{8}</BUDAT>|<BUDAT>12345678</BLDAT>|g;
			$data=~s|<BUDAT>[[:digit:]]{8}</BUDAT>|<BUDAT>12345678</BUDAT>|g;
			
		}
		
		# changes by uppuram
		if ($interface eq 'MARATL91') {
			$data=~s|<NTANF>[[:digit:]]{8}</NTANF>|<NTANF>12345678</NTANF>|g; 
			$data=~s|<NTEND>[[:digit:]]{8}</NTEND>|<NTEND>12345678</NTEND>|g; 
			$data=~s|<NTENZ>[[:digit:]]{6}</NTENZ>|<NTANF>123456</NTENZ>|g; 
			$data=~s|<INSMK/>||g;
			$data=~s|<INSMK></INSMK>||g;
			$data=~s|<ZE1EDL24/>||g;
			$data=~s|<ZE1EDL24></ZE1EDL24>||g;
			
		}	
		# changes by uppuram
		if ($interface eq 'MARATL92') {
			$data=~s|<RECORD_DATE>[[:digit:]]{8}</RECORD_DATE>|<RECORD_DATE>12345678</RECORD_DATE>|g; 
			$data=~s|<RECORD_TIME>(.)*</RECORD_TIME>|<RECORD_TIME>12345</RECORD_TIME>|g; 
			$data=~s|<NTANF>[[:digit:]]{8}</NTANF>|<NTANF>12345678</NTANF>|g; 
			$data=~s|<NTEND>[[:digit:]]{8}</NTEND>|<NTEND>12345678</NTEND>|g; 
			$data=~s|<NTENZ>[[:digit:]]{6}</NTENZ>|<NTENZ>123456</NTENZ>|g; 
			
		}	
		# changes by uppuram
		if ($interface eq 'MARATL93') {
		    $data=~s|<BESTQ/>||g;
			$data=~s|<BESTQ></BESTQ>||g;
			$data=~s|<IDATU>[[:digit:]]{8}</IDATU>|<IDATU>12345678</IDATU>|g; 
		}	
		
		if ($interface eq 'PRMATL02') {
		
			$data=~s|<CREAT_DATE>[[:digit:]]{8}</CREAT_DATE>|<CREAT_DATE>XCREDATX</CREAT_DATE>|g;
			
		} 

		if ($interface eq 'SKEATL01') {
		
			$data=~s|<SERIAL>(.){14}</SERIAL>|<SERIAL>12345678901234</SERIAL>|g;
			$data=~s|<SERIALIZATIONCNT>(.){14}</SERIALIZATIONCNT>|<SERIALIZATIONCNT>12345678901234</SERIALIZATIONCNT>|g;
			#print $IDENTIFIER, "\n", "WMB7:\n", $data, "\n";

		}	
		
		if ($interface eq 'APLATL10') {
			$data=~s|<SERIAL>(.){14}</SERIAL>|<SERIAL>12345678901234</SERIAL>|g;
			$data=~s|<SERIALIZATIONCNT>(.){14}</SERIALIZATIONCNT>|<SERIALIZATIONCNT>12345678901234</SERIALIZATIONCNT>|g;
			#print $IDENTIFIER, "\n", "WMB7:\n", $data, "\n";
		}
		
		if ($interface eq 'NAPATL01') {
						
			$data=~s|<TRADE_ID/>||g;
			$data=~s|<TRADE_ID></TRADE_ID>||g;
			$data=~s|<OBJ_KEY>(.)*</OBJ_KEY>|<OBJ_KEY>0000</OBJ_KEY>|g;
		
		}
		
		if ($interface eq 'CONATL02') {
		
			$data=~s|<DOC_DATE>(.)*</DOC_DATE>|<DOC_DATE>20171215</DOC_DATE>|g;
			$data=~s|<PSTNG_DATE>(.)*</PSTNG_DATE>|<PSTNG_DATE>20171215</PSTNG_DATE>|g;
			$data=~s|<OBJ_KEY>(.)*</OBJ_KEY>|<OBJ_KEY>0000</OBJ_KEY>|g;
			$data=~s|<HEADER_TXT>(.)*</HEADER_TXT>|<HEADER_TXT>TEXT</HEADER_TXT>|g;
			$data=~s|<ITEM_TEXT>(.)*</ITEM_TEXT>|<ITEM_TEXT>TEXT</ITEM_TEXT>|g;
			
			#print $IDENTIFIER, "\n", "WMB7:\n", $data, "\n";

		}
		
		
		if ($interface eq 'CONATL04') {		
			$data=~s|<DOC_DATE>(.)*</DOC_DATE>|<DOC_DATE>20171215</DOC_DATE>|g;
			$data=~s|<PSTNG_DATE>(.)*</PSTNG_DATE>|<PSTNG_DATE>20171215</PSTNG_DATE>|g;
			$data=~s|<OBJ_KEY>(.)*</OBJ_KEY>|<OBJ_KEY>0000</OBJ_KEY>|g;
			#$data=~s|<HEADER_TXT>(.)*</HEADER_TXT>|<HEADER_TXT>TEXT</HEADER_TXT>|g;
			#$data=~s|<ITEM_TEXT>(.)*</ITEM_TEXT>|<ITEM_TEXT>TEXT</ITEM_TEXT>|g;
			$data=~s|<COMP_CODE/>||g;
			$data=~s|<COMP_CODE></COMP_CODE>||g;
			#print $IDENTIFIER, "\n", "WMB7:\n", $data, "\n";

		}
		
		if ($interface eq 'CONATL05') {		
			$data=~s|<DOC_DATE>(.)*</DOC_DATE>|<DOC_DATE>20171215</DOC_DATE>|g;
			$data=~s|<PSTNG_DATE>(.)*</PSTNG_DATE>|<PSTNG_DATE>20171215</PSTNG_DATE>|g;
			$data=~s|<OBJ_KEY>(.)*</OBJ_KEY>|<OBJ_KEY>0000</OBJ_KEY>|g;
			#$data=~s|<HEADER_TXT>(.)*</HEADER_TXT>|<HEADER_TXT>ABCDEFGHIJKLMNOPQRSTU</HEADER_TXT>|g;
			$data=~s|<HEADER_TXT>(.)*</HEADER_TXT>|<HEADER_TXT>TEXT</HEADER_TXT>|g;
			#$data=~s|<ITEM_TEXT>(.)*</ITEM_TEXT>|<ITEM_TEXT>TEXT</ITEM_TEXT>|g;			
			#$print $IDENTIFIER, "\n", "WMB7:\n", $data, "\n";
		}
		
		if ($interface eq 'ODYATL01') {
						
			$data=~s|<ITEM_TEXT/>||g;
			$data=~s|<ITEM_TEXT></ITEM_TEXT>||g;
			
		}
		
		if ($interface eq 'CISATL10') {
			$data=~s|<VSART/>||g;
			$data=~s|<AUGRU/>||g;
			$data=~s|<ABRVW/>||g;
			$data=~s|<PSTYV/>||g;
			$data=~s|<WERKS/>||g;
			$data=~s|<LGORT/>||g;
			$data=~s|<ROUTE/>||g;
		}
		
		if ($interface eq 'CISATL20') {
			$data=~s|<VFDAT>\n</VFDAT>||g; # Removing empty xml tag of VFDAT, with LF in WMB7 output
			$data=~s|<ZCERTIFICATE>\n</ZCERTIFICATE>||g;
			$data=~s|<KOSTL></KOSTL>||g;
			$data=~s|<KOSTL/>||g;
			$data=~s|<GRUND></GRUND>||g;
			$data=~s|<GRUND/>||g;
			$data=~s|<VFDAT></VFDAT>||g;
			$data=~s|<VFDAT/>||g;
			$data=~s|<FRBNR></FRBNR>||g;
			$data=~s|<FRBNR/>||g;
			$data=~s|<ZCERTIFICATE></ZCERTIFICATE>||g;
			$data=~s|<ZCERTIFICATE/>||g;
		}
		
		if ($interface eq 'CISATL14') {
			$data=~s|<AUART/>||g;
			$data=~s|<KPEIN/>||g;
		}
		
		if ($interface eq 'DGLPAN03') {
		
			#$data=~s|\n||g; # Removing any line feed (LF) in WMB7 output
			#$data=~s|\s{2,}||g; # Removing spaces of the XML indent in WMB7 output
			$data=~s|<CRI015></CRI015>||g;
			$data=~s|<CRI015>    </CRI015>||g;
			
		}
						
		if ($interface eq 'CISATL13') {
		
			$data=~s|<ZZPALBASE_DEL01>\s+|<ZZPALBASE_DEL01>|g; # Removing any leading space in xml tag of ZZPALBASE_DEL01 in WMB7 output
			$data=~s|\s+</ZZPALBASE_DEL01>|</ZZPALBASE_DEL01>|g; # Removing any trailing space in xml tag of ZZPALBASE_DEL01 in WMB7 output
			$data=~s|<ZZPALBASE_DEL02>\s+|<ZZPALBASE_DEL02>|g;
			$data=~s|\s+</ZZPALBASE_DEL02>|</ZZPALBASE_DEL02>|g;
			$data=~s|<ZZPALBASE_DEL03>\s+|<ZZPALBASE_DEL03>|g;
			$data=~s|\s+</ZZPALBASE_DEL03>|</ZZPALBASE_DEL03>|g;
			$data=~s|<ZZPALBASE_DEL04>\s+|<ZZPALBASE_DEL04>|g;
			$data=~s|\s+</ZZPALBASE_DEL04>|</ZZPALBASE_DEL04>|g;
			$data=~s|<ZZPALBASE_DEL05>\s+|<ZZPALBASE_DEL05>|g;
			$data=~s|\s+</ZZPALBASE_DEL05>|</ZZPALBASE_DEL05>|g;
			
		}
		
		if ($interface eq 'CISATL21') {
		
			$data=~s|<ZZPALSPACE_DELIV/>||g;
			$data=~s|<ZZPALSPACE_DELIV></ZZPALSPACE_DELIV>||g;
			$data=~s|<ZZPALSPACE_DELIV>\n</ZZPALSPACE_DELIV>||g;	
			$data=~s|<ZZPALBASE_DEL01/>||g;
			$data=~s|<ZZPALBASE_DEL01></ZZPALBASE_DEL01>||g;
			$data=~s|<ZZPALBASE_DEL01>\n</ZZPALBASE_DEL01>||g;
			$data=~s|<ZZPALBASE_DEL02/>||g;
			$data=~s|<ZZPALBASE_DEL02></ZZPALBASE_DEL02>||g;
			$data=~s|<ZZPALBASE_DEL02>\n</ZZPALBASE_DEL02>||g;
			$data=~s|<ZZPALBASE_DEL03/>||g;
			$data=~s|<ZZPALBASE_DEL03></ZZPALBASE_DEL03>||g;
			$data=~s|<ZZPALBASE_DEL03>\n</ZZPALBASE_DEL03>||g;
			$data=~s|<ZZPALBASE_DEL04/>||g;
			$data=~s|<ZZPALBASE_DEL04></ZZPALBASE_DEL04>||g;
			$data=~s|<ZZPALBASE_DEL04>\n</ZZPALBASE_DEL04>||g;
			$data=~s|<ZZPALBASE_DEL05/>||g;
			$data=~s|<ZZPALBASE_DEL05></ZZPALBASE_DEL05>||g;
			$data=~s|<ZZPALBASE_DEL05>\n</ZZPALBASE_DEL05>||g;
			
		}
		
		if ($interface eq 'CISATL23') {
			$data=~s|<VFDAT/>||g;
			$data=~s|<VFDAT></VFDAT>||g;
		}
		
		if ($interface eq 'CISATL22') {
			$data=~s|<STATXT>VA      -                              </STATXT>|<STATXT>VA-</STATXT>|g;
		}
		
		if ($interface eq 'CISATL30') {
			$data=~s|<DOC_DATE>[[:digit:]]*</DOC_DATE>|<DOC_DATE>DOC_DATE</DOC_DATE>|g; # Replacing value in xml tag of DOC_DATE with fixed string "DOC_DATE" in WMB7 output
			$data=~s|<MAT_GRP>         </MAT_GRP>|<MAT_GRP/>|g;
		}
		
		if ($interface eq 'CISATL31') {
			$data=~s|<MESCOD>\s+|<MESCOD>|g;
			$data=~s|\s+</MESCOD>|</MESCOD>|g;
			$data=~s|<MESCOD/>||g;
			$data=~s|<MESCOD></MESCOD>||g;
			$data=~s|<OBJ_SYS>\s+|<OBJ_SYS>|g;
			$data=~s|\s+</OBJ_SYS>|</OBJ_SYS>|g;
			$data=~s|<OBJ_SYS/>||g;
			$data=~s|<OBJ_SYS></OBJ_SYS>||g;
			$data=~s|<OBJ_TYPE>\s+|<OBJ_TYPE>|g;
			$data=~s|\s+</OBJ_TYPE>|</OBJ_TYPE>|g;
			$data=~s|<OBJ_TYPE/>||g;
			$data=~s|<OBJ_TYPE></OBJ_TYPE>||g;
			$data=~s|<AC_DOC_NO>\s+|<AC_DOC_NO>|g;
			$data=~s|\s+</AC_DOC_NO>|</AC_DOC_NO>|g;
			$data=~s|<AC_DOC_NO/>||g;
			$data=~s|<AC_DOC_NO></AC_DOC_NO>||g;
			$data=~s|<EXCH_RATE>\s+|<EXCH_RATE>|g;
			$data=~s|\s+</EXCH_RATE>|</EXCH_RATE>|g;
			$data=~s|<EXCH_RATE/>||g;
			$data=~s|<EXCH_RATE></EXCH_RATE>||g;
			$data=~s|<EXCH_RATE_V>\s+|<EXCH_RATE_V>|g;
			$data=~s|\s+</EXCH_RATE_V>|</EXCH_RATE_V>|g;
			$data=~s|<EXCH_RATE_V/>||g;
			$data=~s|<EXCH_RATE_V></EXCH_RATE_V>||g;
			$data=~s|<DISTR_CHAN>\s+|<DISTR_CHAN>|g;
			$data=~s|\s+</DISTR_CHAN>|</DISTR_CHAN>|g;
			$data=~s|<DISTR_CHAN/>||g;
			$data=~s|<DISTR_CHAN></DISTR_CHAN>||g;
			$data=~s|<DISC_BASE>\s+|<DISC_BASE>|g;
			$data=~s|\s+</DISC_BASE>|</DISC_BASE>|g;
			$data=~s|<DISC_BASE/>||g;
			$data=~s|<DISC_BASE></DISC_BASE>||g;
			$data=~s|<ITEM_TEXT>\s+|<ITEM_TEXT>|g;
			$data=~s|\s+</ITEM_TEXT>|</ITEM_TEXT>|g;
			$data=~s|<ITEM_TEXT/>||g;
			$data=~s|<ITEM_TEXT></ITEM_TEXT>||g;
			$data=~s|<HEADER_TXT>\s+|<HEADER_TXT>|g;
			$data=~s|\s+</HEADER_TXT>|</HEADER_TXT>|g;
			$data=~s|<HEADER_TXT/>||g;
			$data=~s|<HEADER_TXT></HEADER_TXT>||g;
			$data=~s|<AMT_DOCCUR>\s+|<AMT_DOCCUR>|g;
			$data=~s|\s+</AMT_DOCCUR>|</AMT_DOCCUR>|g;
			$data=~s|<AMT_DOCCUR/>||g;
			$data=~s|<AMT_DOCCUR></AMT_DOCCUR>||g;
			$data=~s|<SALESORG>\s+|<SALESORG>|g;
			$data=~s|\s+</SALESORG>|</SALESORG>|g;
			$data=~s|<SALESORG/>||g;
			$data=~s|<SALESORG></SALESORG>||g;
			$data=~s|<COMP_CODE>\s+|<COMP_CODE>|g;
			$data=~s|\s+</COMP_CODE>|</COMP_CODE>|g;
			$data=~s|<COMP_CODE/>||g;
			$data=~s|<COMP_CODE></COMP_CODE>||g;
			$data=~s|<PROFIT_CTR>\s+|<PROFIT_CTR>|g;
			$data=~s|\s+</PROFIT_CTR>|</PROFIT_CTR>|g;
			$data=~s|<PROFIT_CTR/>||g;
			$data=~s|<PROFIT_CTR></PROFIT_CTR>||g;
			$data=~s|<CUSTOMER>\s+|<CUSTOMER>|g;
			$data=~s|\s+</CUSTOMER>|</CUSTOMER>|g;
			$data=~s|<CUSTOMER/>||g;
			$data=~s|<CUSTOMER></CUSTOMER>||g;
			$data=~s|<PLANT>\s+|<PLANT>|g;
			$data=~s|\s+</PLANT>|</PLANT>|g;
			$data=~s|<PLANT/>||g;
			$data=~s|<PLANT></PLANT>||g;
			$data=~s|<MATERIAL>\s+|<MATERIAL>|g;
			$data=~s|\s+</MATERIAL>|</MATERIAL>|g;
			$data=~s|<MATERIAL/>||g;
			$data=~s|<MATERIAL></MATERIAL>||g;
			$data=~s|<BASE_UOM>\s+|<BASE_UOM>|g;
			$data=~s|\s+</BASE_UOM>|</BASE_UOM>|g;
			$data=~s|<BASE_UOM/>||g;
			$data=~s|<BASE_UOM></BASE_UOM>||g;
			$data=~s|<QUANTITY>\s+|<QUANTITY>|g;
			$data=~s|\s+</QUANTITY>|</QUANTITY>|g;
			$data=~s|<QUANTITY/>||g;
			$data=~s|<QUANTITY></QUANTITY>||g;
			$data=~s|<WBS_ELEMENT>\s+|<WBS_ELEMENT>|g;
			$data=~s|\s+</WBS_ELEMENT>|</WBS_ELEMENT>|g;
			$data=~s|<WBS_ELEMENT/>||g;
			$data=~s|<WBS_ELEMENT></WBS_ELEMENT>||g;
			$data=~s|<ORDERID>\s+|<ORDERID>|g;
			$data=~s|\s+</ORDERID>|</ORDERID>|g;
			$data=~s|<ORDERID/>||g;
			$data=~s|<ORDERID></ORDERID>||g;
			$data=~s|<COSTCENTER>\s+|<COSTCENTER>|g;
			$data=~s|\s+</COSTCENTER>|</COSTCENTER>|g;
			$data=~s|<COSTCENTER/>||g;
			$data=~s|<COSTCENTER></COSTCENTER>||g;
			$data=~s|<TAX_CODE>\s+|<TAX_CODE>|g;
			$data=~s|\s+</TAX_CODE>|</TAX_CODE>|g;
			$data=~s|<TAX_CODE/>||g;
			$data=~s|<TAX_CODE></TAX_CODE>||g;
			$data=~s|<ALLOC_NMBR>\s+|<ALLOC_NMBR>|g;
			$data=~s|\s+</ALLOC_NMBR>|</ALLOC_NMBR>|g;
			$data=~s|<ALLOC_NMBR/>||g;
			$data=~s|<ALLOC_NMBR></ALLOC_NMBR>||g;
			$data=~s|<COND_KEY>\s+|<COND_KEY>|g;
			$data=~s|\s+</COND_KEY>|</COND_KEY>|g;
			$data=~s|<COND_KEY/>||g;
			$data=~s|<COND_KEY></COND_KEY>||g;
			$data=~s|<ACCT_KEY>\s+|<ACCT_KEY>|g;
			$data=~s|\s+</ACCT_KEY>|</ACCT_KEY>|g;
			$data=~s|<ACCT_KEY/>||g;
			$data=~s|<ACCT_KEY></ACCT_KEY>||g;
			$data=~s|<TRANS_DATE>\s+|<TRANS_DATE>|g;
			$data=~s|\s+</TRANS_DATE>|</TRANS_DATE>|g;
			$data=~s|<TRANS_DATE/>||g;
			$data=~s|<TRANS_DATE></TRANS_DATE>||g;
			$data=~s|<REF_DOC_NO>\s+|<REF_DOC_NO>|g;
			$data=~s|\s+</REF_DOC_NO>|</REF_DOC_NO>|g;
			$data=~s|<REF_DOC_NO/>||g;
			$data=~s|<REF_DOC_NO></REF_DOC_NO>||g;
			$data=~s|<PMNTTRMS>\s+|<PMNTTRMS>|g;
			$data=~s|\s+</PMNTTRMS>|</PMNTTRMS>|g;
			$data=~s|<PMNTTRMS/>||g;
			$data=~s|<PMNTTRMS></PMNTTRMS>||g;
			$data=~s|<BLINE_DATE>\s+|<BLINE_DATE>|g;
			$data=~s|\s+</BLINE_DATE>|</BLINE_DATE>|g;
			$data=~s|<BLINE_DATE/>||g;
			$data=~s|<BLINE_DATE></BLINE_DATE>||g;
			$data=~s|<PMNT_BLOCK>\s+|<PMNT_BLOCK>|g;
			$data=~s|\s+</PMNT_BLOCK>|</PMNT_BLOCK>|g;
			$data=~s|<PMNT_BLOCK/>||g;
			$data=~s|<PMNT_BLOCK></PMNT_BLOCK>||g;
			$data=~s|<W_TAX_CODE>\s+|<W_TAX_CODE>|g;
			$data=~s|\s+</W_TAX_CODE>|</W_TAX_CODE>|g;
			$data=~s|<W_TAX_CODE/>||g;
			$data=~s|<W_TAX_CODE></W_TAX_CODE>||g;
			$data=~s|<CURRENCY>\s+|<CURRENCY>|g;
			$data=~s|\s+</CURRENCY>|</CURRENCY>|g;
			$data=~s|<CURRENCY/>||g;
			$data=~s|<CURRENCY></CURRENCY>||g;
		}
		
		if ($interface eq 'CISATL05') {
			$data=~s|<PARTNER_Q> </PARTNER_Q>|<PARTNER_Q></PARTNER_Q>|g;
			$data=~s|<PARTNER_Q>   </PARTNER_Q>|<PARTNER_Q></PARTNER_Q>|g;
			$data=~s|<PARTNER_ID>                 </PARTNER_ID>|<PARTNER_ID></PARTNER_ID>|g;
			$data=~s|<ZE1ADRM1><PARTNER_Q></PARTNER_Q><PARTNER_ID></PARTNER_ID></ZE1ADRM1>||g;
			$data=~s|<ZE1ADRM1><PARTNER_Q/><PARTNER_ID/></ZE1ADRM1>||g;
			$data=~s|<ZE1ADRM1><PARTNER_ID></PARTNER_ID></ZE1ADRM1>||g;
			$data=~s|<ZE1ADRM1/>||g;
			$data=~s|\s+</XBLNR>|</XBLNR>|g;
			$data=~s|<XBLNR>\s+|<XBLNR>|g;
			$data=~s|<XBLNR/>||g;
			$data=~s|<XBLNR></XBLNR>||g;
			$data=~s|<XBLNR>                </XBLNR>||g;
			$data=~s|\s+</EBELN>|</EBELN>|g;
			$data=~s|<EBELN>\s+|<EBELN>|g;
			$data=~s|<EBELN/>||g;
			$data=~s|<EBELN></EBELN>||g;
			$data=~s|\s+</EBELP>|</EBELP>|g;
			$data=~s|<EBELP>\s+|<EBELP>|g;
			$data=~s|<EBELP/>||g;
			$data=~s|<EBELP></EBELP>||g;
			$data=~s|\s+</LIFNR>|</LIFNR>|g;
			$data=~s|<LIFNR>\s+|<LIFNR>|g;
			$data=~s|<LIFNR/>||g;
			$data=~s|<LIFNR></LIFNR>||g;
			$data=~s|\s+</KZBEW>|</KZBEW>|g;
			$data=~s|<KZBEW>\s+|<KZBEW>|g;
			$data=~s|<KZBEW/>||g;
			$data=~s|<KZBEW></KZBEW>||g;
			$data=~s|<E1MBXYJ><EXIDV/></E1MBXYJ>||g;
			$data=~s|<E1MBXYJ/>||g;
			$data=~s|\s+</GRUND>|</GRUND>|g;
			$data=~s|<GRUND>\s+|<GRUND>|g;
			$data=~s|<GRUND/>||g;
			$data=~s|<GRUND></GRUND>||g;
			$data=~s|\s+</ZZEXREF>|</ZZEXREF>|g;
			$data=~s|<ZZEXREF>\s+|<ZZEXREF>|g;
			$data=~s|<ZZEXREF/>||g;
			$data=~s|<ZZEXREF></ZZEXREF>||g;
			$data=~s|[A-Z]</ZZEXREF>|</ZZEXREF>|g;
			$data=~s|\s+</SOBKZ>|</SOBKZ>|g;
			$data=~s|<SOBKZ>\s+|<SOBKZ>|g;
			$data=~s|<SOBKZ/>||g;
			$data=~s|<SOBKZ></SOBKZ>||g;
			$data=~s|\s+</VFDAT>|</VFDAT>|g;
			$data=~s|<VFDAT>\s+|<VFDAT>|g;
			$data=~s|<VFDAT/>||g;
			$data=~s|<VFDAT></VFDAT>||g;
			$data=~s|\s+</FRBNR>|</FRBNR>|g;
			$data=~s|<FRBNR>\s+|<FRBNR>|g;
			$data=~s|<FRBNR/>||g;
			$data=~s|<FRBNR></FRBNR>||g;
			$data=~s|<UMMAT>\n</UMMAT>||g;
			$data=~s|<UMMAT></UMMAT>||g;
			$data=~s|<UMMAT/>||g;
			$data=~s|<UMCHA>\n</UMCHA>||g;
			$data=~s|<UMCHA></UMCHA>||g;
			$data=~s|<UMCHA/>||g;
			$data=~s|<LICHA>\n</LICHA>||g;
			$data=~s|<LICHA></LICHA>||g;
			$data=~s|<LICHA/>||g;
			$data=~s|<ZE1MBXYI></ZE1MBXYI>||g;
			$data=~s|<ZE1MBXYI/>||g;
		}
		
		if ($interface eq 'CISATL32') {
			$data=~s|<AUGRU></AUGRU>||g;
			$data=~s|<ZICBDATA><ZCNN_NUM></ZCNN_NUM></ZICBDATA>|<ZICBDATA/>|g;
			$data=~s|<ORGID></ORGID>||g;
			$data=~s|<PSTYV></PSTYV>||g;
			$data=~s|<WERKS></WERKS>||g;
			$data=~s|<LGORT></LGORT>||g;
			$data=~s|<VSTEL></VSTEL>||g;
			$data=~s|<BELNR></BELNR>||g;						
		}
		
		
		
		
		if ($interface eq 'CISATL33') {
			$data=~s|<SERIAL>[[:digit:]]*</SERIAL>|<SERIAL>SERIAL</SERIAL>|g;
			$data=~s|<SERIALIZATIONCNT>[[:digit:]]*</SERIALIZATIONCNT>|<SERIALIZATIONCNT>SERIALIZATIONCNT</SERIALIZATIONCNT>|g;
		}
		
		
		#if ($interface eq 'STDATL01') {
		#	$data=~s|\s+</TDLINE>|</TDLINE>|g;
		#	$data=~s|<TDLINE>\s+|<TDLINE>|g;
		#	$data=~s|<TDLINE/>||g;
		#	$data=~s|<TDLINE></TDLINE>||g;
		#}
		
		# Write production output details into cache file, including dashboard ID, msg datetime, queue name & MD5 value
		print $fh $IDENTIFIER, ";", $PUT_DATE, ";", $QUEUE_NAME, ";", md5_hex($data), "\n";
		
		close $fh;
	}
}

sub cache_dashboard_outputs($) {
	my ($interface)=@_;
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
	mkpath "${cache_folder}/${interface}";
	my $last_cached=int('0'.`find ${cache_folder}/${interface} -type f | while IFS= read -r f; do cut -d ';' -f 1 "\$f"; done | sort -rn 2>/dev/null | head -1`);
	print gmtime()." INFO: caching Prod dashboard data; last cached IDENTIFIER is ${last_cached}\n";
	my $sth1=$dh->prepare("
SELECT
	hmm.IDENTIFIER
FROM
	HUB_MQSI_MSG hmm,
	HUB_DATA hd_dh,
	HUB_DATA hd_d
WHERE
	hmm.IDENTIFIER>:1 AND
	hmm.PUT_DATE<(select cast(put_date/1000000-1 as int)*1000000 from hub_mqsi_msg where identifier=(select max(identifier) from hub_mqsi_msg)) AND
	hmm.DATA_HEADER_IDENTIFIER=hd_dh.DATA_IDENTIFIER AND
	hmm.DATA_IDENTIFIER=hd_d.DATA_IDENTIFIER AND
	hmm.MESSAGE_TYPE=1 AND
	hmm.TIER=0 AND
	hmm.INTERFACE_ID=:2
ORDER BY hmm.IDENTIFIER
	") || die "Can't prepare SQL";
	$sth1->bind_param(1, $last_cached);
	$sth1->bind_param(2, $interface);
	print gmtime()." INFO:  retrieving record IDENTIFIERs in Prod from dashboard\n";
	$sth1->execute() || die "Can't execute SQL";
	print gmtime()." INFO:  going through the found IDENTIFIERs\n";
	my $n_processed=0;
	my $rows=[];
	while ($rows=$sth1->fetchall_arrayref(undef, 1000)) {
		my @to_cache=map {$_->[0]} @$rows;
		cache_identifiers($dh, $interface, \@to_cache);
		$n_processed+=@$rows;
		print gmtime()." INFO:   processed ${n_processed} IDENTIFIERs\n";
	}
}

sub test($) {
	my ($interface)=@_;
	print gmtime()." INFO: starting to submit Prod files in Devl\n";
	foreach my $dqmi (0..$#dqms) {
		$dqms[$dqmi]{qmh}=MQSeries::QueueManager->new(
			QueueManager=>$dqms[$dqmi]{QueueManager},
			ClientConn=>$dqms[$dqmi]{ClientConn}
		);
	}
	my $interface_mqft_config=read_interface_mqft_config($interface, GWAYD_LOGIN, GWAYD_HOST, GWAYD_MQFT_CONFIG);
	my $target_path=(split '=', $interface_mqft_config)[0];
	rmtree "${temp_folder}/$$";
	mkpath "${temp_folder}/$$";
	my @rows=
		sort
			{$b->[1] cmp $a->[1]}
			map
				{
					my $local_path=$_;
					die "Failed to parse $_"
						unless 2==scalar(my ($host, $safe_path)=(m|^.*/([^/.]*)[.]([^/]*)$|));
					(my $path=$safe_path)=~s/#/\//g;
					[$host, $safe_path, $path, $local_path]
				}
				grep
					{!/.ok$/ && !/.lost$/}
					glob($cache_folder.'/'.$interface.'/*.*');
	print gmtime()." INFO:  found ", $#rows+1, " file(s) to be processed\n";
	my $success=0;
	my $processed=0;
	my $mh;
	foreach my $row (@rows) {
		my ($host, $safe_path, $path, $local_path)=@$row;
		print gmtime()." INFO:  (".++$processed.") processing ${host}:${path}\n";
		print `scp -q '${\GWAYP_LOGIN}\@${host}:${path}*' ${temp_folder}/${$}`;
		(my $xpath=$path)=~s/\/prod\//\/prod\/archive\//;
		print `scp -q '${\GWAYP_LOGIN}\@${host}:${xpath}*' ${temp_folder}/${$}`;
		my @copied=glob("${temp_folder}/${$}/*");
		if ($#copied<0) {
			print gmtime()." INFO: file ${host}:${path} is not available anymore - renaming into .lost\n";
			move(
				"${cache_folder}/${interface}/${host}.${safe_path}",
				"${cache_folder}/${interface}/${host}.${safe_path}.lost"
			);
			next;
		}
		die "Multiple test files found in ${host}: ", join(',', @copied)
			if $#copied>0;
		my $copied=$copied[0];
		if ($copied=~m/[.]gz$/) {
			`gunzip ${copied}`;
			$copied=~s/.gz$//;
		}
		my $md5sum12=substr((split ' ', `md5sum ${copied}`)[0], 0, 12);
		my @expected=map
			{
				@_=split ';', $_;
				{
					identifier=>$_[0],
					put_date=>$_[1],
					queue=>$_[2],
					md5=>$_[3],
					URL=>'http://dashbdp1.na.mars/prodtool/HUB_msgdata.pl?Identifier='.$_[0].'&config=/opt/apps/dashboard/prod/config/webtool.config'
				}
			}
			split
				"\n",
				`cat ${cache_folder}/${interface}/${host}.${safe_path}`;
		my $expected_count=$#expected+1;
		my %x=map {$_=>1} (map {$_->{queue}} @expected);
		my @queues=keys(%x);
		foreach my $queue (@queues) {
			foreach my $dqmi (0..$#dqms) {
				print gmtime()." INFO:   cleaning up queue ".$dqms[$dqmi]{QueueManager}.":$queue\n";
				$dqms[$dqmi]{queues}{$queue}=MQSeries::Queue->new(
					QueueManager=>$dqms[$dqmi]{qmh},
					Queue=>$queue,
					Mode=>'input'
				) || die "Cannot open output queue ".$dqms[$dqmi]{QueueManager}.":$queue"
					unless defined $dqms[$dqmi]{queues}{$queue};
				my $n=-1;
				do {
					$n++;
				} while ($dqms[$dqmi]{queues}{$queue}->Get(Message=>($mh=MQSeries::Message->new()), Convert=>0, Wait=>'1s')>0);
				print gmtime()." INFO:    ${n} removed\n";
			}
		}
		print gmtime()." INFO:   submitting to ${\GWAYD_HOST}:${target_path}\n";
		my $target_folder=dirname $target_path;
		print `ssh -qn ${\GWAYD_LOGIN}\@${\GWAYD_HOST} 'mkdir -p ${target_folder}'`;
		print `scp -q ${copied} ${\GWAYD_LOGIN}\@${\GWAYD_HOST}:${target_path}`;
		print `ssh -qn ${\GWAYD_LOGIN}\@${\GWAYD_HOST} '/opt/apps/ims/perl/mqfts_sched_exit.pl ${md5sum12}\`date +%Y%m%d%H%M%S\` IIBTEST test.dat ${\GWAYD_NAME} ${target_path} 0 0'`;
		unlink $copied;
		print gmtime()." INFO:   it's expected to get ", $#expected+1, " output(s)\n";
		print 'Expected: ', Dumper \@expected;
		print 'Queues: ', Dumper \@queues;
		my $matched=0;
		my @no_match=();
		do {
			my $found=0;
			foreach my $queue (@queues) {
				foreach my $dqmi (0..$#dqms) {
					#print 'Trying: ', Dumper $dqms[$dqmi]{queues}{$queue};
					my $re=$dqms[$dqmi]{queues}{$queue}->Get(Message=>($mh=MQSeries::Message->new()), Convert=>0);
					die "Queue ".$dqms[$dqmi]{QueueManager}.":${queue} read failure"
						unless $re;
					if ($re>0) {
						#@dqms=(splice(@dqms, $dqmi, 1), ); 
						$found=1;
						my $data=$mh->Data();
								
						# In case any valid discrepancies have to be skipped, script update needs to be performed here for substitution in IIB10 test outputs. Same updates should be made here as changes in WMB7 outputs
						
						$data=~s|<CREDAT>[[:digit:]]{8}</CREDAT>|<CREDAT>XCREDATX</CREDAT>|g;
						$data=~s|<CRETIM>[[:digit:]]{6}</CRETIM>|<CRETIM>CRETIM</CRETIM>|g;
						
						if ($interface eq 'QROATL11') {
							my ($date, $time)=($copied=~/.*d2m_(.{8})_(.{6}).*/);
							$date=substr(gm2put_date(put_date2gm($date.$time)+60*60*4), 0, 8);
							$data=~s|(<DELIV_DATE>)[[:digit:]]{8}(</DELIV_DATE>)|$1${date}$2|g;
						}
						
						if ($interface eq 'QROATL02') {
							my ($date, $time)=($copied=~/.*d2m_(.{8})_(.{6}).*/);
							$date=substr(gm2put_date(put_date2gm($date.$time)+60*60*4), 0, 8);
							$data=~s|(<TRANS_DATE>)[[:digit:]]{8}(</TRANS_DATE>)|$1${date}$2|g;
						}
						
						if ($interface eq 'BTBUSA64') {
							my ($date, $time)=($copied=~/.*d2m_(.{8})_(.{6}).*/);
							$date=substr(gm2put_date(put_date2gm($date.$time)+60*60*4), 0, 8);
							$data=~s|(<PSTNG_DATE>)[[:digit:]]{8}(</PSTNG_DATE>)|$1${date}$2|g;
							$data=~s|(<OBJ_KEY>.{6})[[:digit:]]{8}([^<]*</OBJ_KEY>)|$1${date}$2|g;
							$data=~s|(<CREDAT>)[[:digit:]]{8}(</CREDAT>)|$1${date}$2|g; 
						}
						
						if ($interface eq 'NAPATL01') {
										
							$data=~s|<TRADE_ID/>||g;
							$data=~s|<TRADE_ID></TRADE_ID>||g;
							$data=~s|<OBJ_KEY>(.)*</OBJ_KEY>|<OBJ_KEY>0000</OBJ_KEY>|g;
						
						}
						
						if ($interface eq 'SKEATL01') {
						
							$data=~s|<SERIAL>(.){14}</SERIAL>|<SERIAL>12345678901234</SERIAL>|g;
							$data=~s|<SERIALIZATIONCNT>(.){14}</SERIALIZATIONCNT>|<SERIALIZATIONCNT>12345678901234</SERIALIZATIONCNT>|g;		
							#print "IIB10:\n", $data, "\n";
							
						}
						
						if ($interface eq 'APLATL10') {
							$data=~s|<SERIAL>(.){14}</SERIAL>|<SERIAL>12345678901234</SERIAL>|g;
							$data=~s|<SERIALIZATIONCNT>(.){14}</SERIALIZATIONCNT>|<SERIALIZATIONCNT>12345678901234</SERIALIZATIONCNT>|g;
							#print "IIB10:\n", $data, "\n";
						}
						
						if ($interface eq 'CONATL02') {
						
							$data=~s|<DOC_DATE>(.)*</DOC_DATE>|<DOC_DATE>20171215</DOC_DATE>|g;
							$data=~s|<PSTNG_DATE>(.)*</PSTNG_DATE>|<PSTNG_DATE>20171215</PSTNG_DATE>|g;
							$data=~s|<OBJ_KEY>(.)*</OBJ_KEY>|<OBJ_KEY>0000</OBJ_KEY>|g;
							$data=~s|<HEADER_TXT>(.)*</HEADER_TXT>|<HEADER_TXT>TEXT</HEADER_TXT>|g;
							$data=~s|<ITEM_TEXT>(.)*</ITEM_TEXT>|<ITEM_TEXT>TEXT</ITEM_TEXT>|g;							
							#print "IIB10:\n", $data, "\n";							
						}
						
						if ($interface eq 'CONATL04') {							
							$data=~s|<DOC_DATE>(.)*</DOC_DATE>|<DOC_DATE>20171215</DOC_DATE>|g;
							$data=~s|<PSTNG_DATE>(.)*</PSTNG_DATE>|<PSTNG_DATE>20171215</PSTNG_DATE>|g;
							$data=~s|<OBJ_KEY>(.)*</OBJ_KEY>|<OBJ_KEY>0000</OBJ_KEY>|g;
							#$data=~s|<HEADER_TXT>(.)*</HEADER_TXT>|<HEADER_TXT>TEXT</HEADER_TXT>|g;
							#$data=~s|<ITEM_TEXT>(.)*</ITEM_TEXT>|<ITEM_TEXT>TEXT</ITEM_TEXT>|g;
							$data=~s|<COMP_CODE/>||g;
							$data=~s|<COMP_CODE></COMP_CODE>||g;			
							
							#print "IIB10:\n", $data, "\n";
						}
						
						if ($interface eq 'CONATL05') {		
							$data=~s|<DOC_DATE>(.)*</DOC_DATE>|<DOC_DATE>20171215</DOC_DATE>|g;
							$data=~s|<PSTNG_DATE>(.)*</PSTNG_DATE>|<PSTNG_DATE>20171215</PSTNG_DATE>|g;
							$data=~s|<OBJ_KEY>(.)*</OBJ_KEY>|<OBJ_KEY>0000</OBJ_KEY>|g;
							#$data=~s|<HEADER_TXT>(.)*</HEADER_TXT>|<HEADER_TXT>ABCDEFGHIJKLMNOPQRSTU</HEADER_TXT>|g;
							$data=~s|<HEADER_TXT>(.)*</HEADER_TXT>|<HEADER_TXT>TEXT</HEADER_TXT>|g;
							#$data=~s|<ITEM_TEXT>(.)*</ITEM_TEXT>|<ITEM_TEXT>TEXT</ITEM_TEXT>|g;			
							#$print "IIB10:\n", $data, "\n";
						}
						
						if ($interface eq 'ODYATL01') {
										
							$data=~s|<ITEM_TEXT/>||g;
							$data=~s|<ITEM_TEXT></ITEM_TEXT>||g;
							
						}
						
						if ($interface eq 'MERATL01') {
						
							 $data=~s|<PSTNG_DATE>[[:digit:]]{8}</PSTNG_DATE>|<PSTNG_DATE>01234567</PSTNG_DATE>|g;
							 $data=~s|<REF_KEY_1/>||g;
							 $data=~s|<REF_KEY_1></REF_KEY_1>||g;
							 $data=~s|<REF_KEY_2/>||g;
							 $data=~s|<REF_KEY_2></REF_KEY_2>||g;	
							 $data=~s|<REF_KEY_3/>||g;
							 $data=~s|<REF_KEY_3></REF_KEY_3>||g;
							 
						}
		
						if ($interface eq 'CISATL10') {
							$data=~s|<VSART/>||g;
							$data=~s|<AUGRU/>||g;
							$data=~s|<ABRVW/>||g;
							$data=~s|<PSTYV/>||g;
							$data=~s|<WERKS/>||g;
							$data=~s|<LGORT/>||g;
							$data=~s|<ROUTE/>||g;
						}
						
						if ($interface eq 'CISATL32') {
							$data=~s|<AUGRU></AUGRU>||g;
							$data=~s|<ZICBDATA><ZCNN_NUM></ZCNN_NUM></ZICBDATA>|<ZICBDATA/>|g;
							$data=~s|<ORGID></ORGID>||g;
							$data=~s|<PSTYV></PSTYV>||g;
							$data=~s|<WERKS></WERKS>||g;
							$data=~s|<LGORT></LGORT>||g;
							$data=~s|<VSTEL></VSTEL>||g;
							$data=~s|<BELNR></BELNR>||g;						
						}
						
						if ($interface eq 'ASUATL08') {
						
							$data=~s|<SERIAL>[[:digit:]]*</SERIAL>|<SERIAL>SERIALXXXXXXXX</SERIAL>|g;
							$data=~s|<SERIALIZATIONCNT>[[:digit:]]*</SERIALIZATIONCNT>|<SERIALIZATIONCNT>SERIALXXXXXXXX</SERIALIZATIONCNT>|g;
							#		$data=~s|<DELETE></DELETE>||g;
							#		$data=~s|</DELETE>||g;

						}
				
				
						if ($interface eq 'WARATL01'){
						
							$data=~s|<CHAR_VALUE></CHAR_VALUE>||g;
							$data=~s|<CHAR_VALUE/>||g;
							
							print "IIB10:\n", $data, "\n";

						}

						if ($interface eq 'PLSATL02'){

                                                        $data=~s|<CHAR_VALUE></CHAR_VALUE>||g;
                                                        $data=~s|<CHAR_VALUE/>||g;

                                                }


						if ($interface eq 'MESATL01'){

							$data=~s|<CHAR_VALUE></CHAR_VALUE>||g;
							$data=~s|<CHAR_VALUE/>||g;

						}
						
						if ($interface eq 'MESATL02'){

							$data=~s|\n||g;
							$data=~s|>(\s)*<|><|g;
							#$data=~s| encoding=\"utf-8\"||g;
							#print "IIB10:\n", $data, "\n";
						}
						
						if ($interface eq 'CISATL20') {
							$data=~s|<VFDAT>\n</VFDAT>||g;
							$data=~s|<ZCERTIFICATE>\n</ZCERTIFICATE>||g;
							$data=~s|<KOSTL></KOSTL>||g;
							$data=~s|<KOSTL/>||g;
							$data=~s|<GRUND></GRUND>||g;
							$data=~s|<GRUND/>||g;
							$data=~s|<VFDAT></VFDAT>||g;
							$data=~s|<VFDAT/>||g;
							$data=~s|<FRBNR></FRBNR>||g;
							$data=~s|<FRBNR/>||g;
							$data=~s|<ZCERTIFICATE></ZCERTIFICATE>||g;
							$data=~s|<ZCERTIFICATE/>||g;
						}
							
							if ($interface eq 'QITATL10') {
							$data=~s|<BUDAT>[[:digit:]]{8}</BUDAT>|<BUDAT>20170908</BUDAT>|g;
						    $data=~s|<CHARG/>||g;
							$data=~s|<SOBKZ/>||g;
					    }

						if ($interface eq 'MARATL90') {
		
			                $data=~s|<BLDAT>[[:digit:]]{8}</BUDAT>|<BUDAT>12345678</BLDAT>|g;
			                $data=~s|<BUDAT>[[:digit:]]{8}</BUDAT>|<BUDAT>12345678</BUDAT>|g;
			
						}
						
						# changes by uppuram
						if ($interface eq 'MARATL91') {
						$data=~s|<NTANF>[[:digit:]]{8}</NTANF>|<NTANF>12345678</NTANF>|g; 
						$data=~s|<NTEND>[[:digit:]]{8}</NTEND>|<NTEND>12345678</NTEND>|g; 
						$data=~s|<NTENZ>[[:digit:]]{6}</NTENZ>|<NTANF>123456</NTENZ>|g; 
						$data=~s|<INSMK/>||g;
						$data=~s|<INSMK></INSMK>||g;
						$data=~s|<ZE1EDL24/>||g;
						$data=~s|<ZE1EDL24></ZE1EDL24>||g;
						}	
						
						# changes by uppuram
						if ($interface eq 'MARATL92') {
						$data=~s|<RECORD_DATE>[[:digit:]]{8}</RECORD_DATE>|<RECORD_DATE>12345678</RECORD_DATE>|g; 
						$data=~s|<RECORD_TIME>(.)*</RECORD_TIME>|<RECORD_TIME>12345</RECORD_TIME>|g;
						$data=~s|<NTANF>[[:digit:]]{8}</NTANF>|<NTANF>12345678</NTANF>|g; 
						$data=~s|<NTEND>[[:digit:]]{8}</NTEND>|<NTEND>12345678</NTEND>|g; 
						$data=~s|<NTENZ>[[:digit:]]{6}</NTENZ>|<NTENZ>123456</NTENZ>|g; 						
			
						}	

						# changes by uppuram
						if ($interface eq 'MARATL93') {
							$data=~s|<BESTQ/>||g;
							$data=~s|<BESTQ></BESTQ>||g;
							$data=~s|<IDATU>[[:digit:]]{8}</IDATU>|<IDATU>12345678</IDATU>|g; 
						}							
						
						if ($interface eq 'CISATL22') {
							$data=~s|<STATXT>VA      -                              </STATXT>|<STATXT>VA-</STATXT>|g;
						}
						
						if ($interface eq 'DGLPAN03') {
							#$data=~s|\n||g; # Removing any line feed (LF) in WMB7 output
							#$data=~s|\s{2,}||g; # Removing spaces of the XML indent in WMB7 output
							$data=~s|<CRI015></CRI015>||g;
							$data=~s|<CRI015>    </CRI015>||g;
							
						}
							
						if ($interface eq 'ASUTRI01') {
						
							$data=~s|<VERSION/>||g;
							$data=~s|<VERSION></VERSION>||g;
							$data=~s|<VERSION> </VERSION>||g;
							$data=~s|<FIRMING_IND/>||g;
							$data=~s|<FIRMING_IND></FIRMING_IND>||g;
							$data=~s|<FIRMING_IND> </FIRMING_IND>||g;
							$data=~s|<FIXED_VEND/>||g;
							$data=~s|<FIXED_VEND></FIXED_VEND>||g;
							$data=~s|<FIXED_VEND> </FIXED_VEND>||g;
							
						}

						if ($interface eq 'DGLPAN05') {
						
							$data=~s|<SPEC_STOCK></SPEC_STOCK>||g; 
							$data=~s|<SPEC_STOCK> </SPEC_STOCK>||g;
							$data=~s|<SPEC_STOCK>||g;
							$data=~s|</SPEC_STOCK>||g;
			
						}
							
						if ($interface eq 'HPSGBR01') {	
						
							$data=~s|<REF_DOC_NO></REF_DOC_NO>||g;
							$data=~s|<REF_DOC_NO/>||g;
							$data=~s|<ALLOC_NMBR></ALLOC_NMBR>||g;
							$data=~s|<ALLOC_NMBR/>||g;
							
						}
						
						if ($interface eq 'CISATL30') {
							$data=~s|<DOC_DATE>[[:digit:]]*</DOC_DATE>|<DOC_DATE>DOC_DATE</DOC_DATE>|g;
							$data=~s|<MAT_GRP>         </MAT_GRP>|<MAT_GRP/>|g;
						}
						
						if ($interface eq 'CISATL31') {
							$data=~s|<MESCOD>\s+|<MESCOD>|g;
							$data=~s|\s+</MESCOD>|</MESCOD>|g;
							$data=~s|<MESCOD/>||g;
							$data=~s|<MESCOD></MESCOD>||g;
							$data=~s|<OBJ_SYS>\s+|<OBJ_SYS>|g;
							$data=~s|\s+</OBJ_SYS>|</OBJ_SYS>|g;
							$data=~s|<OBJ_SYS/>||g;
							$data=~s|<OBJ_SYS></OBJ_SYS>||g;
							$data=~s|<OBJ_TYPE>\s+|<OBJ_TYPE>|g;
							$data=~s|\s+</OBJ_TYPE>|</OBJ_TYPE>|g;
							$data=~s|<OBJ_TYPE/>||g;
							$data=~s|<OBJ_TYPE></OBJ_TYPE>||g;
							$data=~s|<AC_DOC_NO>\s+|<AC_DOC_NO>|g;
							$data=~s|\s+</AC_DOC_NO>|</AC_DOC_NO>|g;
							$data=~s|<AC_DOC_NO/>||g;
							$data=~s|<AC_DOC_NO></AC_DOC_NO>||g;
							$data=~s|<EXCH_RATE>\s+|<EXCH_RATE>|g;
							$data=~s|\s+</EXCH_RATE>|</EXCH_RATE>|g;
							$data=~s|<EXCH_RATE/>||g;
							$data=~s|<EXCH_RATE></EXCH_RATE>||g;
							$data=~s|<EXCH_RATE_V>\s+|<EXCH_RATE_V>|g;
							$data=~s|\s+</EXCH_RATE_V>|</EXCH_RATE_V>|g;
							$data=~s|<EXCH_RATE_V/>||g;
							$data=~s|<EXCH_RATE_V></EXCH_RATE_V>||g;
							$data=~s|<DISTR_CHAN>\s+|<DISTR_CHAN>|g;
							$data=~s|\s+</DISTR_CHAN>|</DISTR_CHAN>|g;
							$data=~s|<DISTR_CHAN/>||g;
							$data=~s|<DISTR_CHAN></DISTR_CHAN>||g;
							$data=~s|<DISC_BASE>\s+|<DISC_BASE>|g;
							$data=~s|\s+</DISC_BASE>|</DISC_BASE>|g;
							$data=~s|<DISC_BASE/>||g;
							$data=~s|<DISC_BASE></DISC_BASE>||g;
							$data=~s|<ITEM_TEXT>\s+|<ITEM_TEXT>|g;
							$data=~s|\s+</ITEM_TEXT>|</ITEM_TEXT>|g;
							$data=~s|<ITEM_TEXT/>||g;
							$data=~s|<ITEM_TEXT></ITEM_TEXT>||g;
							$data=~s|<HEADER_TXT>\s+|<HEADER_TXT>|g;
							$data=~s|\s+</HEADER_TXT>|</HEADER_TXT>|g;
							$data=~s|<HEADER_TXT/>||g;
							$data=~s|<HEADER_TXT></HEADER_TXT>||g;
							$data=~s|<AMT_DOCCUR>\s+|<AMT_DOCCUR>|g;
							$data=~s|\s+</AMT_DOCCUR>|</AMT_DOCCUR>|g;
							$data=~s|<AMT_DOCCUR/>||g;
							$data=~s|<AMT_DOCCUR></AMT_DOCCUR>||g;
							$data=~s|<SALESORG>\s+|<SALESORG>|g;
							$data=~s|\s+</SALESORG>|</SALESORG>|g;
							$data=~s|<SALESORG/>||g;
							$data=~s|<SALESORG></SALESORG>||g;
							$data=~s|<COMP_CODE>\s+|<COMP_CODE>|g;
							$data=~s|\s+</COMP_CODE>|</COMP_CODE>|g;
							$data=~s|<COMP_CODE/>||g;
							$data=~s|<COMP_CODE></COMP_CODE>||g;
							$data=~s|<PROFIT_CTR>\s+|<PROFIT_CTR>|g;
							$data=~s|\s+</PROFIT_CTR>|</PROFIT_CTR>|g;
							$data=~s|<PROFIT_CTR/>||g;
							$data=~s|<PROFIT_CTR></PROFIT_CTR>||g;
							$data=~s|<CUSTOMER>\s+|<CUSTOMER>|g;
							$data=~s|\s+</CUSTOMER>|</CUSTOMER>|g;
							$data=~s|<CUSTOMER/>||g;
							$data=~s|<CUSTOMER></CUSTOMER>||g;
							$data=~s|<PLANT>\s+|<PLANT>|g;
							$data=~s|\s+</PLANT>|</PLANT>|g;
							$data=~s|<PLANT/>||g;
							$data=~s|<PLANT></PLANT>||g;
							$data=~s|<MATERIAL>\s+|<MATERIAL>|g;
							$data=~s|\s+</MATERIAL>|</MATERIAL>|g;
							$data=~s|<MATERIAL/>||g;
							$data=~s|<MATERIAL></MATERIAL>||g;
							$data=~s|<BASE_UOM>\s+|<BASE_UOM>|g;
							$data=~s|\s+</BASE_UOM>|</BASE_UOM>|g;
							$data=~s|<BASE_UOM/>||g;
							$data=~s|<BASE_UOM></BASE_UOM>||g;
							$data=~s|<QUANTITY>\s+|<QUANTITY>|g;
							$data=~s|\s+</QUANTITY>|</QUANTITY>|g;
							$data=~s|<QUANTITY/>||g;
							$data=~s|<QUANTITY></QUANTITY>||g;
							$data=~s|<WBS_ELEMENT>\s+|<WBS_ELEMENT>|g;
							$data=~s|\s+</WBS_ELEMENT>|</WBS_ELEMENT>|g;
							$data=~s|<WBS_ELEMENT/>||g;
							$data=~s|<WBS_ELEMENT></WBS_ELEMENT>||g;
							$data=~s|<ORDERID>\s+|<ORDERID>|g;
							$data=~s|\s+</ORDERID>|</ORDERID>|g;
							$data=~s|<ORDERID/>||g;
							$data=~s|<ORDERID></ORDERID>||g;
							$data=~s|<COSTCENTER>\s+|<COSTCENTER>|g;
							$data=~s|\s+</COSTCENTER>|</COSTCENTER>|g;
							$data=~s|<COSTCENTER/>||g;
							$data=~s|<COSTCENTER></COSTCENTER>||g;
							$data=~s|<TAX_CODE>\s+|<TAX_CODE>|g;
							$data=~s|\s+</TAX_CODE>|</TAX_CODE>|g;
							$data=~s|<TAX_CODE/>||g;
							$data=~s|<TAX_CODE></TAX_CODE>||g;
							$data=~s|<ALLOC_NMBR>\s+|<ALLOC_NMBR>|g;
							$data=~s|\s+</ALLOC_NMBR>|</ALLOC_NMBR>|g;
							$data=~s|<ALLOC_NMBR/>||g;
							$data=~s|<ALLOC_NMBR></ALLOC_NMBR>||g;
							$data=~s|<COND_KEY>\s+|<COND_KEY>|g;
							$data=~s|\s+</COND_KEY>|</COND_KEY>|g;
							$data=~s|<COND_KEY/>||g;
							$data=~s|<COND_KEY></COND_KEY>||g;
							$data=~s|<ACCT_KEY>\s+|<ACCT_KEY>|g;
							$data=~s|\s+</ACCT_KEY>|</ACCT_KEY>|g;
							$data=~s|<ACCT_KEY/>||g;
							$data=~s|<ACCT_KEY></ACCT_KEY>||g;
							$data=~s|<TRANS_DATE>\s+|<TRANS_DATE>|g;
							$data=~s|\s+</TRANS_DATE>|</TRANS_DATE>|g;
							$data=~s|<TRANS_DATE/>||g;
							$data=~s|<TRANS_DATE></TRANS_DATE>||g;
							$data=~s|<REF_DOC_NO>\s+|<REF_DOC_NO>|g;
							$data=~s|\s+</REF_DOC_NO>|</REF_DOC_NO>|g;
							$data=~s|<REF_DOC_NO/>||g;
							$data=~s|<REF_DOC_NO></REF_DOC_NO>||g;
							$data=~s|<PMNTTRMS>\s+|<PMNTTRMS>|g;
							$data=~s|\s+</PMNTTRMS>|</PMNTTRMS>|g;
							$data=~s|<PMNTTRMS/>||g;
							$data=~s|<PMNTTRMS></PMNTTRMS>||g;
							$data=~s|<BLINE_DATE>\s+|<BLINE_DATE>|g;
							$data=~s|\s+</BLINE_DATE>|</BLINE_DATE>|g;
							$data=~s|<BLINE_DATE/>||g;
							$data=~s|<BLINE_DATE></BLINE_DATE>||g;
							$data=~s|<PMNT_BLOCK>\s+|<PMNT_BLOCK>|g;
							$data=~s|\s+</PMNT_BLOCK>|</PMNT_BLOCK>|g;
							$data=~s|<PMNT_BLOCK/>||g;
							$data=~s|<PMNT_BLOCK></PMNT_BLOCK>||g;
							$data=~s|<W_TAX_CODE>\s+|<W_TAX_CODE>|g;
							$data=~s|\s+</W_TAX_CODE>|</W_TAX_CODE>|g;
							$data=~s|<W_TAX_CODE/>||g;
							$data=~s|<W_TAX_CODE></W_TAX_CODE>||g;
							$data=~s|<CURRENCY>\s+|<CURRENCY>|g;
							$data=~s|\s+</CURRENCY>|</CURRENCY>|g;
							$data=~s|<CURRENCY/>||g;
							$data=~s|<CURRENCY></CURRENCY>||g;
						}
						
						if ($interface eq 'CISATL02') {
							$data=~s|<ZEXIDV/><ZQMSTAT/>||g;	
						}
						
						if ($interface eq 'CISATL05') {
							$data=~s|<PARTNER_Q> </PARTNER_Q>|<PARTNER_Q></PARTNER_Q>|g;
							$data=~s|<PARTNER_Q>   </PARTNER_Q>|<PARTNER_Q></PARTNER_Q>|g;
							$data=~s|<PARTNER_ID>                 </PARTNER_ID>|<PARTNER_ID></PARTNER_ID>|g;
							$data=~s|<ZE1ADRM1><PARTNER_Q></PARTNER_Q><PARTNER_ID></PARTNER_ID></ZE1ADRM1>||g;
							$data=~s|<ZE1ADRM1><PARTNER_Q/><PARTNER_ID/></ZE1ADRM1>||g;
							$data=~s|<ZE1ADRM1><PARTNER_ID></PARTNER_ID></ZE1ADRM1>||g;
							$data=~s|<ZE1ADRM1/>||g;
							$data=~s|\s+</XBLNR>|</XBLNR>|g;
							$data=~s|<XBLNR>\s+|<XBLNR>|g;
							$data=~s|<XBLNR/>||g;
							$data=~s|<XBLNR></XBLNR>||g;
							$data=~s|<XBLNR>                </XBLNR>||g;
							$data=~s|\s+</EBELN>|</EBELN>|g;
							$data=~s|<EBELN>\s+|<EBELN>|g;
							$data=~s|<EBELN/>||g;
							$data=~s|<EBELN></EBELN>||g;
							$data=~s|\s+</EBELP>|</EBELP>|g;
							$data=~s|<EBELP>\s+|<EBELP>|g;
							$data=~s|<EBELP/>||g;
							$data=~s|<EBELP></EBELP>||g;
							$data=~s|\s+</LIFNR>|</LIFNR>|g;
							$data=~s|<LIFNR>\s+|<LIFNR>|g;
							$data=~s|<LIFNR/>||g;
							$data=~s|<LIFNR></LIFNR>||g;
							$data=~s|\s+</KZBEW>|</KZBEW>|g;
							$data=~s|<KZBEW>\s+|<KZBEW>|g;
							$data=~s|<KZBEW/>||g;
							$data=~s|<KZBEW></KZBEW>||g;
							$data=~s|<E1MBXYJ><EXIDV/></E1MBXYJ>||g;
							$data=~s|<E1MBXYJ/>||g;
							$data=~s|\s+</GRUND>|</GRUND>|g;
							$data=~s|<GRUND>\s+|<GRUND>|g;
							$data=~s|<GRUND/>||g;
							$data=~s|<GRUND></GRUND>||g;
							$data=~s|\s+</ZZEXREF>|</ZZEXREF>|g;
							$data=~s|<ZZEXREF>\s+|<ZZEXREF>|g;
							$data=~s|<ZZEXREF/>||g;
							$data=~s|<ZZEXREF></ZZEXREF>||g;
							$data=~s|[A-Z]</ZZEXREF>|</ZZEXREF>|g;
							$data=~s|\s+</SOBKZ>|</SOBKZ>|g;
							$data=~s|<SOBKZ>\s+|<SOBKZ>|g;
							$data=~s|<SOBKZ/>||g;
							$data=~s|<SOBKZ></SOBKZ>||g;
							$data=~s|\s+</VFDAT>|</VFDAT>|g;
							$data=~s|<VFDAT>\s+|<VFDAT>|g;
							$data=~s|<VFDAT/>||g;
							$data=~s|<VFDAT></VFDAT>||g;
							$data=~s|\s+</FRBNR>|</FRBNR>|g;
							$data=~s|<FRBNR>\s+|<FRBNR>|g;
							$data=~s|<FRBNR/>||g;
							$data=~s|<FRBNR></FRBNR>||g;
							$data=~s|<UMMAT>\n</UMMAT>||g;
							$data=~s|<UMMAT></UMMAT>||g;
							$data=~s|<UMMAT/>||g;
							$data=~s|<UMCHA>\n</UMCHA>||g;
							$data=~s|<UMCHA></UMCHA>||g;
							$data=~s|<UMCHA/>||g;
							$data=~s|<LICHA>\n</LICHA>||g;
							$data=~s|<LICHA></LICHA>||g;
							$data=~s|<LICHA/>||g;
							$data=~s|<ZE1MBXYI></ZE1MBXYI>||g;
							$data=~s|<ZE1MBXYI/>||g;
						}
						
						if ($interface eq 'CISATL13') {
							$data=~s|<ZZPALBASE_DEL01>\s+|<ZZPALBASE_DEL01>|g;
							$data=~s|\s+</ZZPALBASE_DEL01>|</ZZPALBASE_DEL01>|g;
							$data=~s|<ZZPALBASE_DEL02>\s+|<ZZPALBASE_DEL02>|g;
							$data=~s|\s+</ZZPALBASE_DEL02>|</ZZPALBASE_DEL02>|g;
							$data=~s|<ZZPALBASE_DEL03>\s+|<ZZPALBASE_DEL03>|g;
							$data=~s|\s+</ZZPALBASE_DEL03>|</ZZPALBASE_DEL03>|g;
							$data=~s|<ZZPALBASE_DEL04>\s+|<ZZPALBASE_DEL04>|g;
							$data=~s|\s+</ZZPALBASE_DEL04>|</ZZPALBASE_DEL04>|g;
							$data=~s|<ZZPALBASE_DEL05>\s+|<ZZPALBASE_DEL05>|g;
							$data=~s|\s+</ZZPALBASE_DEL05>|</ZZPALBASE_DEL05>|g;
						}
						# changes by uppuram
						if ($interface eq 'PRMATL04') {
						
							$data=~s|<BUDAT>[[:digit:]]{8}</BUDAT>|<BUDAT>XCREDATX</BUDAT>|g;
						    #$data=~s|<USNAM/>|<USNAM>      </USNAM>|g;
							$data=~s|<USNAM></USNAM>||g;
							$data=~s|<USNAM>      </USNAM>||g;
						}  
			
						# changes by uppuram
						if ($interface eq 'PRMATL02') {
							$data=~s|<CREAT_DATE>[[:digit:]]{8}</CREAT_DATE>|<CREAT_DATE>XCREDATX</CREAT_DATE>|g; 
						}  
						
						
						if ($interface eq 'CISATL21') {
							$data=~s|<ZZPALSPACE_DELIV/>||g;
							$data=~s|<ZZPALSPACE_DELIV></ZZPALSPACE_DELIV>||g;
							$data=~s|<ZZPALSPACE_DELIV>\n</ZZPALSPACE_DELIV>||g;	
							$data=~s|<ZZPALBASE_DEL01/>||g;
							$data=~s|<ZZPALBASE_DEL01></ZZPALBASE_DEL01>||g;
							$data=~s|<ZZPALBASE_DEL01>\n</ZZPALBASE_DEL01>||g;
							$data=~s|<ZZPALBASE_DEL02/>||g;
							$data=~s|<ZZPALBASE_DEL02></ZZPALBASE_DEL02>||g;
							$data=~s|<ZZPALBASE_DEL02>\n</ZZPALBASE_DEL02>||g;
							$data=~s|<ZZPALBASE_DEL03/>||g;
							$data=~s|<ZZPALBASE_DEL03></ZZPALBASE_DEL03>||g;
							$data=~s|<ZZPALBASE_DEL03>\n</ZZPALBASE_DEL03>||g;
							$data=~s|<ZZPALBASE_DEL04/>||g;
							$data=~s|<ZZPALBASE_DEL04></ZZPALBASE_DEL04>||g;
							$data=~s|<ZZPALBASE_DEL04>\n</ZZPALBASE_DEL04>||g;
							$data=~s|<ZZPALBASE_DEL05/>||g;
							$data=~s|<ZZPALBASE_DEL05></ZZPALBASE_DEL05>||g;
							$data=~s|<ZZPALBASE_DEL05>\n</ZZPALBASE_DEL05>||g;
						}
						
						if ($interface eq 'CISATL23') {
							$data=~s|<VFDAT/>||g;
							$data=~s|<VFDAT></VFDAT>||g;
						}
						
						if ($interface eq 'BXBUSA50') {
							my ($date, $time)=($copied=~/.*d2m_(.{8})_(.{6}).*/);
							$date=substr(gm2put_date(put_date2gm($date.$time)+60*60*4), 0, 8);
							$data=~s|(<DATUM>)[[:digit:]]{8}(</DATUM>)|$1${date}$2|g;
						}
						
						if ($interface eq 'CISATL33'){
							$data=~s|<SERIAL>[[:digit:]]*</SERIAL>|<SERIAL>SERIAL</SERIAL>|g;
							$data=~s|<SERIALIZATIONCNT>[[:digit:]]*</SERIALIZATIONCNT>|<SERIALIZATIONCNT>SERIALIZATIONCNT</SERIALIZATIONCNT>|g;
						}
						
						if ($interface eq 'AZPATL01') {
							$data=~s|<SERIAL>[[:digit:]]*</SERIAL>|<SERIAL>SERIAL</SERIAL>|g;
							$data=~s|<SERIALIZATIONCNT>[[:digit:]]*</SERIALIZATIONCNT>|<SERIALIZATIONCNT>SERIALIZATIONCNT</SERIALIZATIONCNT>|g;
						}
						
						#if ($interface eq 'STDATL01') {
						#	$data=~s|\s+</TDLINE>|</TDLINE>|g;
						#	$data=~s|<TDLINE>\s+|<TDLINE>|g;
						#	$data=~s|<TDLINE/>||g;
						#	$data=~s|<TDLINE></TDLINE>||g;
						#}
										
						my $x=1;
						my $xml_tree=$parser->parse_string($data);
						my $md5=md5_hex $xml_tree->toString;
						print gmtime()." INFO:  MD5 read: $md5\n";
						
						@expected=grep
							{
								my $r;
								
								# Comparing MD5 values between production and test outputs
								if ($r=(($_->{queue} eq $queue) && ($_->{md5} eq $md5) && $x)) {
									$x=0;
									print gmtime()." INFO:    (",++$matched,") message matched\n";
									print Dumper($_);
								}
								!$r
							}
							@expected;
						push(@no_match, [$queue, $data])
							if $x;
						last;
					}
				}
			}
			mysleep 10, 10
				unless $found;
			print gmtime()." INFO:   ", $#expected+1, " remains not validated yet; ", $#no_match+1, " found with no match\n"
				unless ($#expected-$#no_match)%1000;
		} until ($#expected<=$#no_match);
		mysleep 2, 2;
		if ($#expected<0) {
			print gmtime()." INFO:   success\n";
			move(
				"${cache_folder}/${interface}/${host}.${safe_path}",
				"${cache_folder}/${interface}/${host}.${safe_path}.ok"
			);
			$success++;
		} else {
			print 'expected:', Dumper(\@expected);
			print 'no match:', Dumper(\@no_match);
			print gmtime()." ERROR: see above\n";
			exit 1;
		}
		foreach my $queue (@queues) {
			foreach my $dqmi (0..$#dqms) {
				if ($dqms[$dqmi]{queues}{$queue}->Get(Message=>($mh=MQSeries::Message->new()), Convert=>0)>0) {
					print gmtime()." ERROR: extra message found in ", $dqms[$dqmi]{QueueManager}, ":", ${queue}, "\n", $mh->Data(), "\n";
					exit 1;
				}
			}
		}
	}
	print gmtime()." INFO: during this run $success files are successfully processed, ".($processed-$success)." are skipped\n";
	print gmtime()." INFO: see all runs log below\n";
	print join("\n", glob($cache_folder.'/'.$interface.'/*.*')), "\n";
}

die "$0 interface"
	unless defined $ARGV[0];
my $interface=$ARGV[0]||'';
die "Invalid interface name ${interface}"
	unless $interface=~/[[:upper:]]{6}[[:digit:]]{2}/;
die "Already running for interface ${interface}"
	if `ps -ef | grep -v grep | grep -v $$ | grep perl'.*'\$(basename $0)'.* '${interface}` gt '';
mkpath $log_folder || die "Failed to create ${log_folder}";
my $log_prefix="${log_folder}/${interface}.".gm2put_date(timegm(gmtime())).".$$";
open(STDOUT, "| tee -ai ${log_prefix}.out.txt") || die "Can not redirect STDOUT";
open(STDERR, "| tee -ai ${log_prefix}.err.txt") || die "Can not redirect STDERR";
print gmtime()." INFO: script name is $0\n";
print gmtime()." INFO: interface name is ${interface}\n";

cache_dashboard_outputs($interface);
test($interface);
exit 0;

END {
	print gmtime()." INFO: doing cleanup\n";
	rmtree "${temp_folder}/$$";
}

__END__



