#!/usr/bin/perl

use strict;

# CONFIG

# list of folders for final storage of plot files.
# these files will be read to figure out your current nonces counter.
# these folders can be on a remote host via the $plotSsh var below.
my @plotFolders = ('/mnt/e/burst', '/mnt/f/burst');

# folder to generate plot files into. after building, they will be copied into one of the plotFolders.
# this folder is assumed to be local.
my $cacheFolder = '/mnt/e/plots';
# if you're on windows, the windows path to your cache folder. otherwise make it the same as the cacheFolder.
my $cacheFolderWin = 'e:\plots';

# command to get list of files from the paths above. 1 file per line
my $dirListCmd = qq^ls -1 '#PATH#'^;

# command to get free bytes from the paths above. should output 1 line of only the free bytes
my $freeBytesCmd = qq^df '#PATH#' -B1 -P | tail -n1 | awk '{print \$4}'^;

# Xplotter command with your thread and memory settings
my $plotterCmd = qq^/mnt/c/Users/taylor/Desktop/XPlotter_v1.1/XPlotter_avx2.exe -t 7 -mem 12G^;

# command to move the plot file from the cache to the final storage, then delete it
my $moveCmd = qq^scp -P 2222 #SOURCE# taylor\@10.0.0.6:#DESTINATION#/; rm #SOURCE#^;

# if your plot folders are on another host, configure ssh to run remote commands
my $plotSsh = qq^ssh taylor\@10.0.0.6 -p 2222 #COMMAND#^;

my $numericWalletId = "6791154659383501881";

# your cache folder should have at least twice as much as this
#my $plotFileSizeNonces = 900000; # 235.9 gb
my $plotFileSizeNonces = 500000; # 122.0 gb
#my $plotFileSizeNonces = 10000; # 2.44 gb

# END CONFIG

my $bytesPerNonce = 262144;
my $plotFileSizeBytes = $plotFileSizeNonces * $bytesPerNonce;
my $currentlyMovingFile = '';

# scan plot folders for all existing plot files to figure out the highest nonce
my $currentNonce = 0;
foreach my $plotFolder (@plotFolders) {
	my $cmd = PutPathInCommand($plotFolder, $dirListCmd, $plotSsh);
	my $files = RunCommand($cmd);
	my $thisMaxNonce = GetMaxNonceFromFiles($files);
	if ($thisMaxNonce > $currentNonce) {
		$currentNonce = $thisMaxNonce;
	}
}

# get free space of all our final storage paths
my %storageFreeBytes;
foreach my $plotFolder (@plotFolders) {
	my $cmd = PutPathInCommand($plotFolder, $freeBytesCmd, $plotSsh);
	my $freeBytes = RunCommand($cmd);
	$storageFreeBytes{$plotFolder} = $freeBytes;
	print "$plotFolder: " . BytesToGigabytes($freeBytes) . " gb free.\n";
}

# start our run loop
while (1) {
	print "LOOP START! currentNonce = $currentNonce\n";
	
	# check free space of plot folders and figure out which one to use
	my $plotPath = "";
	my $maxBytesFree = 0;
	foreach my $plotFolder (@plotFolders) {
		my $freeBytes = $storageFreeBytes{$plotFolder};
		if ($freeBytes > $plotFileSizeBytes) {
			$plotPath = $plotFolder;
			$maxBytesFree = $freeBytes;
			last;
		} else {
			if ($freeBytes > $maxBytesFree) {
				$maxBytesFree = $freeBytes;
				$plotPath = $plotFolder;
			}
		}
	}

	if (!$plotPath) {
		# not enough space, use up the remaining
		print "Didn't find any path with enough space available.\n";
		print "Path '$plotPath' has the most space left with " . BytesToGigabytes($maxBytesFree) . " gb.\n";
		if (BytesToGigabytes($maxBytesFree) <= 1) {
			print "Not enough space left on plot drives! All done!\n";
			last;
		}
		$plotFileSizeBytes = $maxBytesFree - ($bytesPerNonce * 100);
		$plotFileSizeNonces = $plotFileSizeBytes / $bytesPerNonce;
		print "Setting plot file size nonces to $plotFileSizeNonces\n";
	} else {
		# we have enough space, can keep going as normal
		print "Using path '$plotPath', " . BytesToGigabytes($maxBytesFree) . " gb free.\n";
	}
	print "Plot size: " .  BytesToGigabytes($plotFileSizeBytes) . " gb.\n";

	# make sure our cache has enough free space
	my $cmd = PutPathInCommand($cacheFolder, $freeBytesCmd);
	my $freeCacheBytes = RunCommand($cmd);
	if ($freeCacheBytes < $plotFileSizeBytes) {
		print "Not enough space left on cache drive! All Done!\n";
		last;
	}
	print "Cache folder has enough free space, " . BytesToGigabytes($freeCacheBytes) . " gb.\n";

	# generating new plot
	$cmd = "$plotterCmd -id $numericWalletId -sn $currentNonce -n $plotFileSizeNonces -path '$cacheFolderWin'";
	# figure out new filename
	my $newPlotFile = $numericWalletId . "_" . $currentNonce . "_" . $plotFileSizeNonces . "_" . $plotFileSizeNonces;
	print "expected plot file: $newPlotFile\n";
	print "\t> $cmd\n";
	system($cmd);

	# increment our current nonce
	$currentNonce += $plotFileSizeNonces;
	# remove free space from our final storage
	$storageFreeBytes{$plotPath} -= $plotFileSizeBytes;

	# make sure file exists
	$newPlotFile = "$cacheFolder/$newPlotFile";
	if (!(-e $newPlotFile)) {
		print "Error, expected plot file does not exist.\n";
		last;
	}

	# wait for previous file move to be done
	if ($currentlyMovingFile) {
		while (-e $currentlyMovingFile) {
			print "Still waitinig on last file to be moved...\n";
			sleep 10;
		}
	}

	# move plot file from cache to final storage
	$currentlyMovingFile = $newPlotFile;
	$cmd = $moveCmd;
	$cmd =~ s/#SOURCE#/$newPlotFile/g;
	$cmd =~ s/#DESTINATION#/$plotPath/g;
	print "\t> $cmd\n";
	# run this in the background
	system("($cmd) &");
}

# $cmd = PutPathInCommand($plotFolder, $freeBytesCmd, $plotSsh);
# my $freeBytes = RunCommand($cmd);
# print "plot folder\t'$plotFolder'\t$freeBytes bytes free\n";
# print "$files\n";

sub PutPathInCommand {
	my $path = $_[0];
	my $cmd = $_[1];
	my $ssh = $_[2];
	$cmd =~ s/#PATH#/$path/g;
	if ($ssh) {
		$ssh =~ s/#COMMAND#/$cmd/g;
		return $ssh;
	}
	return $cmd;
}

sub RunCommand {
	my $cmd = $_[0];
	print "\t> $cmd\n";
	my $rv = `$cmd`;
	chomp $rv;
	return $rv;
}

sub GetMaxNonceFromFiles {
	my @files = split(/\n/, $_[0]);
	my $max = 0;
	foreach my $file (@files) {
		#print "file: $file\n";
		my @parts = split(/_/, $file);
		my $nonce = $parts[2];
		if ($nonce > $max) {
			$max = $nonce;
		}
	}
	return $max;
}

sub BytesToGigabytes {
	return $_[0] / 1024 / 1024 / 1024;
}