#!/usr/bin/perl

use strict;
use warnings;
use Fcntl qw(:flock);
use Getopt::Long qw(:config auto_help);
use Pod::Usage;
use Sys::Hostname;
use FindBin;
use File::Basename qw(dirname fileparse);
use File::Path qw(mkpath);

my  $BASE_DIR = "$FindBin::Bin/..";
my  $CONF_DIR = "$BASE_DIR/conf";
my  $DATA_DIR = "$BASE_DIR/data";
our $LOG_DIR = "$BASE_DIR/log";

my $SCRIPT_FILE   = "$FindBin::Script";
our $LOG_FILE     = ""; # will be set in init_logger
my $EXCLUDE_LIST = "$CONF_DIR/exclude-list.cfg"; # list of procs to exclude
my $STATUS_FILE  = "$DATA_DIR/arming-status.dat"; # hold the arming counter value

# command line parameters
my $PARAMETERS = {
        'help'          => 0,
        'list'          => 0,
        'no-mail'	=> 0,
};

my $hostname = hostname();
my $mailTo     = "dusan.sovic\@gmail.com";
my $mailFrom   = "root\@$hostname";

my $DEFAULT_ARMING_COUNT = 60; # silentPeriod[minutes] = DEFAULT_ARMING_COUNT * pollingCycle[minutes] 


exit main();

sub main {
	init_parameters();
	my $LOG = init_logger();

	# make sure that only one instance is running	
	open SELF, "< $0" or die "Unable to open '$0' for reading: $!";
	unless (flock SELF, LOCK_EX | LOCK_NB) {
		write2log($LOG, "More than one autosys monitoring process is runnin! EXITING...");
		flock SELF, LOCK_EX | LOCK_NB  or die "More than one autosys monitoring process is runnin! EXITING...\n";
	}

	# Prepare service exclude list pattern
	my @excludeList = getExcludeList("$EXCLUDE_LIST");
	my $excludeListPattern;
	
	if ( @excludeList ) {
		chomp(@excludeList);
		$excludeListPattern = join('|', @excludeList);
	}


	# Get the CA Services Status Report (Nr. of services depends on server role)
	my $caStatusReport = qx(/apps/caadm/CA/SharedComponents/bin/ustat) or die "Couldn't execute command: $!";
		
	if ( $PARAMETERS->{'list'} ) {
		print $caStatusReport;
		close ($LOG);
		exit 0;
	} 

	my $alarmFlag = 0;
	my $notRunServices = "";

	foreach my $line ( split /[\r\n]+/, $caStatusReport ) {
        	chomp($line);

		# next if process is in exclude list
		if ( defined $excludeListPattern) {
			next if ( $line =~ m/$excludeListPattern/);
		}

        	# All service names starts with "CA-" prefix
        	next if ( $line !~ m/^CA-.*$/);    # skip all lines what doesn't start with "CA-" prefix
		
		# Catch all not active monitored services	
		if ( $line =~ /not active/ ) {
			$alarmFlag += 1;
			$line =~ s/\s+/ /g; # friendly formatting
			write2log($LOG, "$line");
			$notRunServices = $notRunServices.$line."\n";
		}
	}


	# If at least one of registered procs are not running => notify      
	if ( $alarmFlag > 0 ) {
        	
		my $armingCount = getArmingCount($STATUS_FILE);
		
		# if arming is >0 no email notification We already send one a we don't want to spam
		# until notifications will be re-armed
		if ( $armingCount > 0 ) {
			write2log($LOG, "No Email send as notification is armed. Arming count is '$armingCount'");
			# decrement arming count by -1
			$armingCount -= 1;
			setArmingCount("$STATUS_FILE","$armingCount");
		}
		# send notification
		else {
			# If no exclude list defined put this text to it
			if ( !defined $excludeListPattern ) { $excludeListPattern = "None included"; }
			# Send an email if 'no-mail' flag is not set
			if ( !($PARAMETERS->{'no-mail'}) ) {
				sendMail($mailTo,
                        		"Some registered CA Autosys services are not running on $hostname",
                        		"Not Running Monitored Services:\n===============================\n $notRunServices\nList of NOT Monitored Services (excluded from monitoring):\n==========================================================\n $excludeListPattern $caStatusReport");
				write2log($LOG, "Sending alert email to: $mailTo");
			}
			# set arming count to defaul count value and write it to file
			setArmingCount("$STATUS_FILE","$DEFAULT_ARMING_COUNT");
			write2log($LOG, "Setting arming count to default value: $DEFAULT_ARMING_COUNT");
		}
	}
	# All monitored processes are up and running
	else {
		write2log($LOG, "All monitored processes are up and running.");
		setArmingCount("$STATUS_FILE","0"); # set arming cont to zero "0"
	}

	exit 0;
}

sub init_parameters {
        # Parse all the options
        GetOptions(
                'help|h|?'          	=> \$PARAMETERS->{'help'},
                'list|l'		=> \$PARAMETERS->{'list'},
                'no-mail|n' 		=> \$PARAMETERS->{'no-mail'},
        )
        or pod2usage(2);

        pod2usage(1) if $PARAMETERS->{help};
}
sub init_logger {
	$_ = $SCRIPT_FILE;
        # remove script extension (.pl) if there is any
        s/\.[^\.]*$//;

        $LOG_FILE   = "$_.log";

        mkpath( $LOG_DIR );
	chmod 02775, $LOG_DIR;

	open (FILE, ">>", "$LOG_DIR/$LOG_FILE") or die "Could not open file '$LOG_DIR/$LOG_FILE' $!";
	return ( \*FILE );
}

sub write2log {
	my ($fh, $txt) = @_;
	my  $date = `date +"%Y/%m/%d %T"`;
	chomp ($date);
	print $fh "$date $txt\n";
}

# List of processes to exclude from  monitoring check
sub getExcludeList {
        my ($excludeFile) = @_;
        open (EFH, "<", "$excludeFile") or warn "Could not open file '$excludeFile' $!";
        my @result = <EFH>;
        close (EFH);
        return @result;
}

sub sendMail {
	my ($to, $subject, $txt) = @_;

	open(MAIL, "|/usr/sbin/sendmail -t");
	
	# mail Header
	print MAIL "To: $to\n";
	print MAIL "From: $mailFrom\n";
	print MAIL "Subject: $subject\n\n";
	
	# mail body
	print MAIL "$txt";

	close(MAIL);
	# Inspired by: http://www.cyberciti.biz/faq/sending-mail-with-perl-mail-script/
}

sub getArmingCount {
	my ($statusFile) = @_;
	my $armingCount;
	
	# check if file exist, if not create it
	if ( -e "$statusFile" ) {
		open(DATA, "<", "$statusFile") or die "Could not open file '$statusFile' $!";
		chomp ($armingCount = <DATA>);
	} else {
		# if not exist, create it and set counter to zero 0
		open(DATA, ">", "$statusFile") or die "Could not write to file '$statusFile' $!";
		print DATA "0";
		$armingCount = 0;
	}

	close DATA;
	return ($armingCount);
}

sub setArmingCount {
	my ($statusFile, $armingCount) = @_;

	open(DATA, ">", "$statusFile") or die "Could not write to file '$statusFile' $!";
	print DATA "$armingCount";
	close DATA;
}

__END__

=head1 NAME

autosys-proc-mon.pl  - monitor CA Autosys Services

=head1 SYNOPSIS

autosys-proc-mon.pl [OPTION]

Options:

        -h,--help               print this help message
        -l,--list               list CA Services Status Report
        -n,--no-mail            disable email notifications

=head1 FILES

=head2 F<../bin/autosys-proc-mon.pl>

Script for AutoSys service monitoring.

=head2 F<../conf/exclude-list.cfg>

Configuration file what contains list of all service names what will be excluded from monitoring.
One service name per line.

Example:

=begin html

<pre>
CA-SNMP Trap Multiplexer
CA-SNMP Trap Manager
</pre>

=end html

=head2 F<../data/arming-status.dat>

This datafile holds the value of the "arming" counter. If we detect that monitored service is not running we send an alert email.
To don't generate alert email each polling cycle next email will be send if counter will be set to zero value.

=over 8

=item * Counter is set to 0 if all services are up and running.

=item * If monitored service goes down, alert email is send and counter is set to default value (like 12).

=item * If service is still down we decrement counter by 1 each polling cycle until it reach zero and new alert email can be send.

=item * We can say that counter represent quiet period (like 60 min) when no new mail is send even if monitored service is down.

=back

DON'T edit this file manually as it is fully managed by the script !!!

=head2 F<../log/autosys-proc-mon.log>

Script log all activities to this file.

=head1 AUTHOR

Dusan Sovic < dusan.sovic@gmail.com >

=cut
