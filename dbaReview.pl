#!/usr/bin/env perl 
use strict;
use warnings;
use DBI;
use Data::Dumper;

our %mem;
our %mycnf;
our %opt;
our $dbh;
our %vars;
our %stats;
our %fsinfo;
our %cpu;
our %sys;

$mycnf{host} = "127.0.0.1";

sub get_mycnf {
        # No user / pass was supplied
        if ( -r "/etc/psa/.psa.shadow" ) { # It's a Plesk box
                $mycnf{user} = "admin";
                open DOTPSA, "/etc/psa/.psa.shadow" or warn "Can't open the /etc/psa/.psa.shadow file. $!\n";
                $mycnf{pass} = <DOTPSA>;
                close DOTPSA;
                return;
        }
        open MYCNF, "$ENV{HOME}/.my.cnf" or warn "Can't open the .my.cnf file. $!\n"; # Last resort - check for ~/.my.cnf
        while(<MYCNF>) {
                if(/^(.+?)\s*=\s*"?(.+?)"?\s*$/) {
                        $mycnf{$1} = $2;
                }
        }
        $mycnf{pass} ||= $mycnf{password} if exists $mycnf{password};
        close MYCNF;
}


sub connect_db {
        my $dsn;
        if ($opt{socket}) {
                $dsn = "DBI:mysql:mysql_socket=$opt{socket}";
        } else {
                $dsn = "DBI:mysql:host=$mycnf{host}";
        }
        $dbh = DBI->connect($dsn, $mycnf{user}, $mycnf{pass}) or usage();
}

sub get_stats {
        my $query = $dbh->prepare("SHOW GLOBAL STATUS;");
        $query->execute();
        my @row;
        while(@row = $query->fetchrow_array()) { $stats{$row[0]} = $row[1];}
}

sub get_vars {
        my $query = $dbh->prepare("SHOW VARIABLES;");
        $query->execute();
        my @row;
        while(@row = $query->fetchrow_array()) { $vars{$row[0]} = $row[1]; }
        $vars{'table_cache'} = $vars{'table_open_cache'} if exists $vars{'table_open_cache'};
        unless (defined $vars{'skip_name_resolve'}) { $vars{'skip_name_resolve'} = "NULL";}
        unless (defined $vars{'slow_query_log'}) { $vars{'slow_query_log'} = "NULL";}
        unless (defined $vars{'slow_query_log_file'}) { $vars{'slow_query_log_file'} = "NULL";}
        $vars{'innodb_additional_mem_pool_size'} = exists $vars{'innodb_additional_mem_pool_size'} ? $vars{'innodb_additional_mem_pool_size'} : 0;
        $vars{'innodb_buffer_pool_size'} = exists $vars{'innodb_buffer_pool_size'} ? $vars{'innodb_buffer_pool_size'} : 0;
        $vars{'innodb_log_buffer_size'} = exists $vars{'innodb_log_buffer_size'} ? $vars{'innodb_log_buffer_size'} : 0;
}

sub make_short {
        # number, is it kilobytes?, decimal places
        my ($number, $kb, $d) = @_;
        my $n = 0;
        my $short;

        $d ||= 0;

        if($kb) { while ($number > 1023) { $number /= 1024; $n++; }; }
        else { while ($number > 999) { $number /= 1000; $n++; }; }

        $short = sprintf "%.${d}f%s", $number, ('','k','M','G','T')[$n];
        if($short =~ /^(.+)\.(00)$/) { return $1; } # 12.00 -> 12 but not 12.00k -> 12k

        return $short;
}

sub percent {
        my($is, $of) = @_;
        return sprintf "%.0f", ($is * 100) / ($of ||= 1);
}

sub get_memory_usage {
        open MEMINFO, "/proc/meminfo" or return;
        while( my $line = <MEMINFO>) {
                chomp($line);
                my ($memstat, $memvalue) = split (/:/, $line);
		$memvalue =~ s/^\s+(\d+)\s?\w*/$1/g;
                $mem{$memstat} = $memvalue;
        }
        close MEMINFO;
# MySQL
	$mem{InnoDBBufferPoolSize} = sprintf "%.0f",(((($mem{MemTotal} / 100) * 80) / 1024) / 1024);
        $mem{MySQLBase} = ($vars{'key_buffer_size'} + $vars{'query_cache_size'} + $vars{'innodb_buffer_pool_size'} + $vars{'innodb_additional_mem_pool_size'} + $vars{'innodb_log_buffer_size'});
        $mem{MySQLPerConnection} = ($vars{read_buffer_size} + $vars{read_rnd_buffer_size} + $vars{sort_buffer_size} + $vars{join_buffer_size} + $vars{binlog_cache_size} + $vars{thread_stack});
        $mem{MySQLMaxConnectionConfigured} = ($mem{MySQLPerConnection} * $vars{max_connections});
        $mem{MySQLMaxConnectionUsed} = ($mem{MySQLPerConnection} * $stats{Max_used_connections});
        $mem{MySQLMaxConfigured} = make_short(($mem{MySQLBase} + $mem{MySQLMaxConnectionConfigured}), 1);
        $mem{MySQLMaxUsed} = make_short(($mem{MySQLBase} + $mem{MySQLMaxConnectionUsed}), 1);
	$mem{MySQLUsedPerc} = percent(($mem{MySQLMaxConnectionConfigured} + $mem{MySQLBase}), ($mem{MemTotal} * 1024));
	$mem{MySQLBase} = make_short($mem{MySQLBase});
	$mem{MySQLPerConnection} = make_short($mem{MySQLPerConnection});
# System
	$mem{MemFreePerc} = percent($mem{MemFree},$mem{MemTotal});
	$mem{MemTotal} = make_short(($mem{MemTotal} * 1024), 1);
	$mem{MemFree} = make_short(($mem{MemFree} * 1024), 1);
	$mem{Cached} = exists $mem{Cached} ? make_short(($mem{Cached} * 1014), 1) : "0";
        $mem{SwapUsed} = exists $mem{SwapTotal} ? make_short((($mem{SwapTotal} * 1024) - ($mem{SwapFree} *1024)), 1) : "0";
	$mem{SwapFreePerc} = exists $mem{SwapTotal} ? percent($mem{SwapFree},$mem{SwapTotal}) : "0";
	$mem{SwapTotal} = exists $mem{SwapTotal} ? make_short(($mem{SwapTotal} * 1024), 1) : "0";
	$mem{SwapFree} = exists $mem{SwapTotal} ? make_short(($mem{SwapFree} * 1024), 1) : "0";
}

sub get_disk_usage {
	my @df_out = `/bin/df -lh`;
	foreach (@df_out) {
		if ($_ =~ /\d\%/) {
			my ($line, $filesystem) = split (/% /, $_);
			chomp ($filesystem);
			my @fields = split(/\s+/, $line);
			$fsinfo{$filesystem}{TotalSize} = $fields[1];
			$fsinfo{$filesystem}{Used} = $fields[2];
			$fsinfo{$filesystem}{Available} = $fields[3];
			$fsinfo{$filesystem}{PercentUsed} = $fields[4];
		}
	}
}

sub get_cpu_usage {
	my @lscpu = `lscpu`;
	foreach my $line (@lscpu) {
		chomp($line);
		$line =~ s/[()]//g;
		my ($name, $number) = split /:/, $line;	
		$name =~ s/([\w']+)/\u\L$1/g;
		$name =~ s/\s+//g;
		$number =~ s/^\s+//g;
		$cpu{$name} = $number;
	}
	$cpu{TotalCores} = ($cpu{CoresPerSocket} * $cpu{Sockets});
	$cpu{TotalThreads} = ($cpu{ThreadsPerCore} * $cpu{TotalCores});
	$cpu{Max15MinLoad} = ($cpu{Cpus} * 0.75);
	unless ( -d "/var/log/sa" ) { return;}
        opendir my $dir, "/var/log/sa" or return;
        my @sar_logs = readdir $dir;
        closedir $dir;
        foreach my $log(@sar_logs) {
                next if ($log =~ /sar/);
                next if ($log =~ /^\.\.?$/);
                $cpu{TotalSarLogs}++;
                my @daily_load_ave = `sar -f /var/log/sa/$log -q | egrep -v 'Linux|runq|Average'`;
                foreach my $ldav(@daily_load_ave) {
                        next if ($ldav =~ /^\s?$/);
                        my @fifteen_load_ave = split(' ', $ldav);
                        chomp(@fifteen_load_ave);
                        next unless (defined $fifteen_load_ave[5]);
			$cpu{LoadTotal} += $fifteen_load_ave[5];
			$cpu{LoadCount}++;
                        if ($fifteen_load_ave[5] >= $cpu{Max15MinLoad}) {
                                $cpu{LoadAverageOverCount}++;
                        }
                }
        }
	$cpu{LoadAve} = sprintf '%.0f%%', 100 * (($cpu{LoadTotal} / $cpu{Cpus}) / $cpu{LoadCount});
}

sub get_system_updates {
#%sys
        unless ( -e "/etc/redhat-release" ) { return; }
	($sys{LastKernelVersion}, $sys{LastUpdateTime}) = split (/ {2,}/, `rpm -q kernel --last | head -n1`);	
	$sys{LastUpdateTime} =~ s/\s+(AM|PM).*//g;
	($sys{UptimeSeconds} = `cat /proc/uptime`) =~ s/(^\d+?)\..*/$1/g;
	($sys{TimeOfReboot} = time()) -= $sys{UptimeSeconds};
	$sys{TimeOfReboot} = localtime($sys{TimeOfReboot});
        my ($wday, $mon, $mday, $rtime, $year) = split(' ', $sys{TimeOfReboot});
        chomp($mday);
        if ($mday =~ /^\d$/) { $mday = "0$mday"; }
        $sys{TimeOfReboot} = "$wday $mday $mon $year $rtime";
        $sys{KernelInUse} = `uname -r`;
	$sys{LastKernelVersion} =~ s/kernel-//g;
	$sys{CP1Updates} = `rpm -q yum-p1mh-autoupdates`;
	$sys{CP1Updates} = $? >> 8;
	chomp(%sys);
}

sub print_report {
# Disk usage
	my @disk_alerts;
	print "\n[Disk Usage]\n";
	printf("%5s %5s %5s %5s %-60s\n", "Size","Used","Avail","Use%","Mounted on");
	foreach my $filesystem (keys %fsinfo) {
		printf("%5s %5s %5s %5s %-60s\n", $fsinfo{$filesystem}{TotalSize},$fsinfo{$filesystem}{Used},$fsinfo{$filesystem}{Available},$fsinfo{$filesystem}{PercentUsed},$filesystem);
		if ($fsinfo{$filesystem}{PercentUsed} >= 90) {
			unless ($filesystem =~ /run/) { push @disk_alerts, "The '$filesystem' filesystem is $fsinfo{$filesystem}{PercentUsed}% used.\n";}
		}
	} 
	print "\n";
	foreach(@disk_alerts) { print "$_"; }
	unless (@disk_alerts) { print "No issues found.\n"; }
#
# Memory usage
	print "\n[Memory Usage]\n";
	print "Total memory: $mem{MemTotal} \nFree memory: $mem{MemFree} ($mem{MemFreePerc}%)\nCached: $mem{Cached} \n";
	print "Total swap: $mem{SwapTotal} \nFree swap: $mem{SwapFree} ($mem{SwapFreePerc}%)\n";
	print "MySQL max configured memory: $mem{MySQLMaxConfigured} ($mem{MySQLUsedPerc}%)\n";
	print "MySQL max used memory: $mem{MySQLMaxUsed}\n";
	print "Base memory: $mem{MySQLBase} | Per Connection: $mem{MySQLPerConnection} | Max Connections: $vars{max_connections} | Max used Connections: $stats{Max_used_connections}\n\n";
	if ($mem{MySQLUsedPerc} >= 95) {
		print "MySQL is configured to use up to $mem{MySQLUsedPerc}% of the system memory.\nThis can cause the system to swap to disk & may degrade performance\n";
		$mem{MySQLWarn} = 1;
	}
        if ($mem{SwapFreePerc} <= 90) {
                print  "The system is using $mem{SwapUsed} of swap. This can dramatically reduce MySQL performance.\n";
		$mem{MySQLWarn} = 1;
        }
        if ( `sysctl -n vm.swappiness` > 10 ) {
                print "Swappiness is > 10. This should be set lower than 10 to prevent unnecessary swapping.\n";
		$mem{MySQLWarn} = 1;
        }
	unless (defined $mem{MySQLWarn}) { print "No issues found.\n"; }
#
# CPU usage
	print "\n[CPU Info]\n";
	print "Model: $cpu{ModelName} (x$cpu{Sockets})\nCores: $cpu{TotalCores}\nThreads: $cpu{TotalThreads}\n";
	print "$cpu{TotalSarLogs} day Load Average: $cpu{LoadAve}\n";
	if (defined $cpu{LoadAverageOverCount}) {
		print "\nThe 15min load average was above 75% total utilization on $cpu{LoadAverageOverCount}  times in the last $cpu{TotalSarLogs} days.\n";
	} else {
		print "\nNo issues found. The CPU total utilization has stayed below 75% for the last $cpu{TotalSarLogs} days.\n";
	}
	if ($cpu{Sockets} >= 2 && $vars{innodb_numa_interleave} eq "OFF") {
		print "Non Uniform Memory Access (NUMA) is enabled in the CPUs, but not in MySQL.\n";
		print "Adding innodb_numa_interleave=1 to the MySQL configuration may improve performance.\n";
	}
#
# System Updates
	print "\n[System Updates]\n";
	print "Last update time: $sys{LastUpdateTime}\n";
	print "Last reboot time: $sys{TimeOfReboot}\n";
	print "Kernel in use: $sys{KernelInUse}\n";
	print "Kernel update: $sys{LastKernelVersion}\n";
	if ($sys{KernelInUse} ne $sys{LastKernelVersion}) {
		print "\nA kernel update requires a reboot.\n";
	} else {
		print "\nRunning latest kernel update.\n";
	}
	if ($sys{CP1Updates} eq 0) {
		print "Automatic updating is enabled.\n";
	} else {
		print "Automatic updating is disabled.\n";
	}

#
# Backups


}

sub print_raw_output {
	#print Dumper \%fsinfo;
	#print Dumper \%cpu;
	#print Dumper \%mem;
	#print Dumper \%sys;
}

get_mycnf();
connect_db();
get_stats();
get_vars();
get_disk_usage();
get_memory_usage();
get_cpu_usage();
get_system_updates();
print_report();
print_raw_output();
