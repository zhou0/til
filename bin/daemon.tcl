#!/bin/sh
# the next line restarts using tclsh \
exec tclsh "$0" "$@"


##################
## Program Name     --  daemon.tcl
## Original Author --  Emmanuel Frecon - emmanuel@sics.se
## Description:
##
##    This program provides support for "daemonisation" of programs on UNIX
##    system, so that they can uniquely be started from init.d compatible
##    scripts or from periodic cron scripts.  The preferred way is through
##    init.d scripts and tclsvcd shows an example of how to use this script
##    from a Sys V compatible system.  This is why the default lock, log and
##    and run directories are as they are.  This implementation has only be
##    tested on Linux and requires the /proc virtual file system to work.
##    This implementation has been ported to Windows and is known to work.
##
##    Some examples:
##
##    daemon.tcl -user emmanuel -program test.tcl -- -onearg 1
##
##    would start the program test.tcl as the user emmanuel (only possible
##    if daemon is run from a /bin/su capable account), and would pass it
##    the -onearg 1 argument and value.  Any output issued from test.tcl
##    would be appended to a file named /var/log/test.log.
##
##    daemon.tcl -program test.tcl -kill
##
##    would kill the program started above.
##
##    daemon.tcl -user emmanuel -program test.tcl -watch -force -- -onearg 1
##
##    would start the program test.tcl as the user emmanuel (only possible
##    if daemon is run from a /bin/su capable account), and would pass it
##    the -onearg 1 argument and value.  daemon.tcl would then not end (as
##    in the previous examples).  Instead it would continuously watch for
##    the existence of test.tcl and would restart it if necessary.  Since
##    -force is specified, daemon.tcl will bypass the lock file and
##    actively check for the existence of test.tcl before restarting (if
##    necessary).  If test.tcl is already running, daemon.tcl will simply
##    take it under its control (and restart it if necessary).  The log
##    file would be placed as above.
##
##    daemon.tcl -program test.tcl -kill -watch
##
##    would kill the program started above.  It will also kill the daemon
##    process that continuously watch test.tcl, so that it does not get
##    immediately restarted.
##
##
##################
# Copyright (c) 2004-2005 by the Swedish Institute of Computer Science.
#
# See the file "license.terms" for information on usage and redistribution
# of this file, and for a DISCLAIMER OF ALL WARRANTIES.

array set DMN {
    lockdir         "/var/lock/subsys"
    piddir          "/var/run"
    logdir          "/var/log"
    procdir         "/proc"
    killcmd         "/bin/kill"
    nicecmd         "/bin/nice"
    period          1000
    basename        ""
    program         ""
    user            ""
    verbose         0
    kill            0
    watch           0
    silent          0
    force           0
    finish          0
    nice            0
}

source [file join [file dirname $argv0] argutil.tcl]
argutil::accesslib tcllib

# Now parse the options and put the result into the global state array
package require cmdline

set options \
    "lockdir.arg piddir.arg logdir.arg basename.arg user.arg program.arg nice.arg verbose kill silent watch force -"
set opt_p 0
while { [set err [cmdline::typedGetopt argv $options opt arg]] } {
    if { $err == 1 } {
	if { $opt == "lockdir" } {
	    # Specify in which directory the lock file should be
	    # placed.  This defaults to /var/lock/subsys/
	    set DMN(lockdir) $arg
	    incr opt_p 2
	} elseif { $opt == "piddir" } {
	    # Specify in which directory the pid file should be
	    # placed.  This defaults to /var/run
	    set DMN(piddir) $arg
	    incr opt_p 2
	} elseif { $opt == "logdir" } {
	    # Specify in which directory the log file should be
	    # placed.  This defaults to /var/log
	    set DMN(logdir) $arg
	    incr opt_p 2
	} elseif { $opt == "basename" } {
	    # Specify an alternative basename for the log, lock and
	    # pid files.  If none is specified, this will be the name
	    # of the program, without directory specification and
	    # without extension.
	    set DMN(basename) $arg
	    incr opt_p 2
	} elseif { $opt == "user" } {
	    # Specify a different user to run the program.  Only the
	    # program will be run under that user.  The log file will
	    # be generated by the user that has started daemon.tcl
	    set DMN(user) $arg
	    incr opt_p 2
	} elseif { $opt == "nice" } {
	    # Specify a different priority to run the program at.
	    set DMN(nice) $arg
	    incr opt_p 2
	} elseif { $opt == "program" } {
	    # Specify the path to the (Tcl) program that is controlled
	    # by daemon.tcl.  The program is required not to start at
	    # once but to "live" continuously.
	    set DMN(program) $arg
	    incr opt_p 2
	} elseif { $opt == "verbose" } {
	    # Say a bit more when performing operations.
	    set DMN(verbose) 1
	    incr opt_p 1
	} elseif { $opt == "silent" } {
	    # Be completely silent.
	    set DMN(silent) 1
	    incr opt_p 1
	} elseif { $opt == "kill" } {
	    # Kill the program instead of starting it.
	    set DMN(kill) 1
	    incr opt_p 1
	} elseif { $opt == "watch" } {
	    # Start watching the program for existence and restart it
	    # if necessary.
	    set DMN(watch) 1
	    incr opt_p 1
	} elseif { $opt == "force" } {
	    # Force program starting up even if the lock file exists.
	    # This will have the effect to take over any other
	    # (running) instance of the program and is especially
	    # usefull with the -watch option.
	    set DMN(force) 1
	    incr opt_p 1
	} elseif { $opt == "-" } {
	    # Everything after this option is blindly passed as an
	    # option to the program.
	    incr opt_p 1
	    break
	}
    } elseif { $err < 0 } {
	puts "ERROR: $opt"
	exit 1
    }
}

# Introduce a replacement function for file normalisation, which was
# only introduced in later versions of Tcl.  We test the existence of
# the command through catching the normalisation of a variable that
# always exists, i.e. argv0
if { [catch "file normalize $argv0"] != 0 } {
    argutil::accesslib til
    argutil::loadmodules [list diskutil]

    proc file_normalize { fname } {
	return [::diskutil::absolute_path $fname]
    }
} else {
    proc file_normalize { fname } {
	return [file normalize $fname]
    }
}

# On Windows, we need the process.tcl replacement library, since /proc
# does not exist. This is a bit of a hack but should work fine.
if { $tcl_platform(platform) == "windows" } {
    if { $DMN(verbose) } {
	set loglvl "warn"
    } else {
	set loglvl "critical"
    }

    argutil::accesslib til
    argutil::loadmodules [list process] $loglvl
}



# Command Name     --  checkpid
# Original Author  --  Emmanuel Frecon - emmanuel@sics.se
#
# Check whether one or several processes are running.  Return 1 if
# they all running, 0 otherwise.  This uses the DMN(procdir),
# i.e. /proc directory and is therefor UNIX (Linux?) dependent.
#
# Arguments:
#    pids	- List of process identifiers to check
proc checkpid { pids } {
    global DMN tcl_platform

    set res 1

    if { $tcl_platform(platform) == "windows" } {
	# On windows, we simply look among the running processes if
	# the ones passed as an argument actually exist.
	set running_pids [::process::list]
	foreach pid $pids {
	    set idx [lsearch $running_pids $pid]
	    if { $idx < 0 } {
		set res 0
	    }
	}
    } else {
	set states ""

	# Check thouroughly if every process which identifiers are passed
	# as arguments are running and alive.
	foreach pid $pids {
	    # This implementation is only tested on Linux and depends on
	    # the /proc virtual file system.
	    set piddir [file join $DMN(procdir) $pid]
	    set state "A"

	    # If the (virtual) directory for the current process in the
	    # loop does not exist, then we know that the process does not
	    # exist.  Otherwise, the process might be a zombie (i.e. it
	    # was forked by us, but has not detached yet).  To detect the
	    # second case we open the "stat" file in the directory
	    # containing information for the current process and isolate
	    # the third field of every line (there really should only be
	    # one line!).
	    if { [file isdirectory $piddir] } {
		set fd [open [file join $piddir stat]]
		while { ! [eof $fd] } {
		    set l [gets $fd]
		    set p_state [lindex $l 2]
		    # p_state, the third field can be one of the following:
		    # R (running), S(sleeping interruptable), D(sleeping),
		    # Z(zombie), or T(stopped on a signal)
		    if { $p_state == "Z" } {
			set state "Z"
		    }
		}
		close $fd
	    } else {
		set state "K"
	    }

	    # Once here state can be one of the following: K (Killed) if
	    # the process did not even exist; A (Active) if the process is
	    # alive and in any of the alive states; or Z (Zombie) if the
	    # process is a zombie and not really to be taken into
	    # consideration.
	    if { $state != "A" } {
		set res 0
	    }

	    # Remember the states of the processes so that we can output
	    # some decent verbose output (well... sort of).
	    lappend states $state
	}
	if { $DMN(verbose) } {
	    puts "State of $pids: $states"
	}
    }
    return $res
}


# Command Name     --  killpid
# Original Author  --  Emmanuel Frecon - emmanuel@sics.se
#
# Kill a process if it exists.  Return 1 on success (or if process did
# not even exists, 0 on failure).  This command actually blocks the
# whole process waiting for it to die.
#
# Arguments:
#    pid	- Identifier of process to kill
proc killpid { pid { timebase 100 } } {
    global DMN tcl_platform

    if { [checkpid $pid] } {
	if { $tcl_platform(platform) == "windows" } {
	    ::process::kill $pid
	} else {
	    exec $DMN(killcmd) -TERM $pid
	}
	after $timebase
	if { [checkpid $pid] && [after [expr $timebase * 10]]=="" \
		&& [checkpid $pid] && [after [expr $timebase * 30]]=="" \
		&& [checkpid $pid] } {
	    if { $tcl_platform(platform) == "windows" } {
		::process::kill $pid
	    } else {
		exec $DMN(killcmd) -KILL $pid
	    }
	    after $timebase
	}
	if { [checkpid $pid] } {
	    return 0
	}
    }

    return 1
}


# Command Name     --  check_for_restart
# Original Author  --  Emmanuel Frecon - emmanuel@sics.se
#
# Periodically check for the existence of the processes that are under
# watch and restart these if necessary.
#
# Arguments:
#    pids	- List of processes that we have started.
proc check_for_restart { pids { period -1 } } {
    global DMN

    if { ! [checkpid $pids] } {
	if { $DMN(verbose) } {
	    puts "One of $pids has died, restarting all..."
	}
	foreach pid $pids {
	    set success [killpid $pid]
	}
	set pids [execute 1]
    }

    if { $period >= 0 } {
	after $period check_for_restart [list $pids] $period
    }

    return $pids
}


# Command Name     --  running
# Original Author  --  Emmanuel Frecon - emmanuel@sics.se
#
# Return a list of running processes that we have started (now or
# before).  The list of process identifiers is taken either from the
# file passed as an argument,either from the global pidfile used by
# the program that we daemonise and control.
#
# Arguments:
#    file	- Path to file containing PID descriptions.
proc running { { file "" } } {
    global DMN

    # If no file was specified, we use the default global pidfile,
    # which is the file used in association with the program that we
    # control and daemonise.
    if { $file == "" } {
	set file $DMN(pidfile)
    }

    # Now open the file and consider each line as containing list of
    # process identifiers.  Parse and return the list.  This is
    # primitive, but since we write these files ourselves, that should
    # serve the purpose.
    set pids ""
    if { [catch "open $file" fd] == 0 } {
	while { ! [eof $fd] } {
	    foreach pid [gets $fd] {
		lappend pids $pid
	    }
	}
	close $fd
    }

    return $pids
}


# Command Name     --  kill
# Original Author  --  Emmanuel Frecon - emmanuel@sics.se
#
# Kill a program that has been started in the background using this
# very program.  Performs all necessary book-keeping.  Exit with error
# if something goes wrong.  This command is called whenever the -kill
# option is specified.  Note that the rundir, logdir and lockdir must
# be pointing at the same directories for this operation to succeed
# correctly.
proc kill { } {
    global DMN argv0

    # There is no basename, we cannot run.
    if { $DMN(basename) == "" } {
	exit 1
    }

    # If we were started with the watch option, another daemon process
    # can be watching this program.  We attempt to kill it at first.
    if { $DMN(watch) } {
	set mylock [file join $DMN(piddir) \
			[file rootname [file tail $argv0]]_$DMN(basename).pid]
	set mypid [running $mylock]
	if { [llength $mypid] > 0 && [checkpid $mypid] } {
	    if { [killpid $mypid] } {
		file delete -force -- $mylock
	    } else {
		if { $DMN(verbose) } {
		    puts "Could not kill daemon controller at $mypid!"
		}
	    }
	}
    }

    # Now kill all running processes that are associated to the
    # program that we control.
    set success 1
    foreach pid [running] {
	set success [killpid $pid]
	if { ! $success } {
	    puts "Could not kill $pid!"
	}
    }

    # If we managed to kill them, delete the lock file and the pid
    # file.
    if { $success } {
	file delete -force -- $DMN(pidfile)
	file delete -force -- $DMN(lockfile)
    }

    # Print so nice output in the same manner as the init.d functions
    # do (without the colouring and the tabulations though!).
    if { ! $DMN(silent) } {
	if { $success } {
	    puts " \[  OK  \]"
	} else {
	    puts " \[FAILED\]"
	    exit 1
	}
    }
}


# Command Name     --  execute
# Original Author  --  Emmanuel Frecon - emmanuel@sics.se
#
# This command execute the program in the background.
proc execute { { force 0 } } {
    global DMN argv0 argv tcl_platform

    # We must have a program to start to be able to source something
    # and a basename to store things.
    if { $DMN(program) == "" || $DMN(basename) == "" } {
	exit 1
    }

    # If there already is a lockfile, exit, some other instance of this
    # very process is already running.
    if { ! $force && [file exists $DMN(lockfile)] } {
	if { ! $DMN(silent) } {
	    puts " \[FAILED\]"
	}
	exit 1
    }

    # Guess the name of the script that we will be using to timestamp the
    # standard out and err of the process that we will be starting.  Not
    # finding the timestamper is not really an error, we will proceed
    # anyway.
    set tstamper [file join [file dirname $argv0] timestamper.tcl]
    if { ! [file exists $tstamper] || ! [file readable $tstamper] } {
	set tstamper ""
    } else {
	set tstamper [file_normalize $tstamper]
    }


    # Make sure we have a full path for the program that we are going to
    # run.  This is important since we might be giving the fullpath to
    # bash when running as another user (note that this really is a
    # reminder of a previous non-working version where we had problems
    # with the current directory used by the forked bash).
    if { [file dirname $DMN(program)] == "." } {
	set DMN(program) [file join [pwd] $DMN(program)]
    }


    # Decide upon the TCL command to execute for running the program that
    # we are "daemonising".  Take care of priorities.
    set prioset ""
    if { $DMN(nice) != 0 && $tcl_platform(platform) != "windows" } {
	set prioset "$DMN(nicecmd) -n $DMN(nice)"
    }
    set tclcmd "$prioset [info nameofexecutable] $DMN(program) "
    append tclcmd $argv


    # Now decide upon what to execute.  Things get tricky if we have been
    # requested to run as another user.  In that case, we wish to run from
    # the same directory.  The code below is taken and adapted from the
    # /etc/init.d/functions.  We do not say "-" on the su command line so
    # as to stay in the same directory.  We do not give -m to reinitialise
    # the environment (not sure here).
    if { $DMN(user) == "" || $tcl_platform(platform) == "windows" } {
	set cmd "exec $prioset $tclcmd"
    } else {
	set cmd "exec $prioset /bin/su -s /bin/bash -c \"$tclcmd\" $DMN(user)"
    }

    # Finalise the command.  We take input from... nowhere (this is a
    # daemon!).  We redirect output automatically to a log file.
    # Maybe would we like to turn this off in some cases.  Dunno
    # really.  What is important to notice here though is that the
    # pipe command happens outside of the (possible) su above.  That
    # means that the logfile will be owned by the user that is
    # starting daemon.tcl (typically root), and not the user to which
    # the program is associated.
    if { $tcl_platform(platform) == "windows" } {
	append cmd " "
    } else {
	append cmd " < /dev/null "
    }
    if { $tstamper == "" } {
	append cmd ">>& $DMN(logfile) "
    } else {
	append cmd "|& [info nameofexecutable] \"$tstamper\" -datesensitive -ignorepreformat -outfile \"$DMN(logfile)\""
    }
    append cmd " &"
    if { $DMN(verbose) } {
	puts $cmd
    }

    # Now, go and execute... Change directory to the directory of the
    # program specified on the command line and exec the command.  Catch
    # the result to be able to report errors through the exit code.  We
    # dump *all* the process identifiers to the pid file.  There might
    # indeed be one or two.  The standard killproc() function in Linux
    # actually kills all PIDs in the files, as expected.
    cd [file dirname $DMN(program)]
    set res [catch $cmd pid]
    if { $res == 0 } {
	set fd [open $DMN(pidfile) w]
	puts $fd $pid
	close $fd

	set fd [open $DMN(lockfile) w]
	close $fd

	if { ! $DMN(silent) } {
	    puts " \[  OK  \]"
	}
    } else {
	if { ! $DMN(silent) } {
	    puts " \[FAILED\]"
	}
	exit 1
    }

    return $pid
}


# Command Name     --  make_liveness_dir
# Original Author  --  Emmanuel Frecon - emmanuel@sics.se
#
# Create one of the liveness directories if it does not already
# exists.  Dumps errors to the user if not silent.
#
# Arguments:
#    dir	- Path to liveness directory
#    descr	- Textual description of directory
proc make_liveness_dir { dir { descr "directory" } } {
    global DMN

    if { ! [file isdirectory $dir] } {
	if { $DMN(verbose) } {
	    puts "Creating $descr at '$dir'"
	}
	if { [catch {file mkdir $dir} err] } {
	    if { ! $DMN(silent) } {
		puts "Error when creating $descr: $err"
	    }
	    return 0
	}
    }

    return 1
}


# Attempt to create the liveness directories
make_liveness_dir $DMN(lockdir) "lock directory"
make_liveness_dir $DMN(piddir) "run directory"
make_liveness_dir $DMN(logdir) "log directory"

# Guess a good basename from the script name if nothing was given on
# the command line.
if { $DMN(basename) == "" } {
    set DMN(basename) [file rootname [file tail $DMN(program)]]
}

# Now resolve the files that we will be taking care of
set DMN(lockfile) [file join $DMN(lockdir) $DMN(basename).lck]
set DMN(pidfile) [file join $DMN(piddir) $DMN(basename).pid]
set DMN(logfile) [file join $DMN(logdir) $DMN(basename).log]

if { $DMN(kill) } {
    # If we have requested a killing procedure, then send kill to the
    # already running instance of the program that we control, to the
    # logging process associated (if any) and to the (if -watch was
    # specified) daemon that controls it.
    kill
} else {

    # Otherwise, we are attempting to start things up...
    set mylock [file join $DMN(piddir) \
		    [file rootname [file tail $argv0]]_$DMN(basename).pid]

    # -force means that we want to bypass the lock file and actually
    # look into the existing pidfile that is associated to the
    # program.  If the pidfile exists, we will "take over" these
    # processes.  Otherwise, we simply start them.
    if { $DMN(force) } {
	# If there is already another daemon looking over this
	# program, we are going to interfer and that is not desired
	# behaviour.  Let the other daemon controlling things and exit
	# immediately.  Mediate an error through the exit code.
	set mypid [running $mylock]
	if { [llength $mypid] > 0 && [checkpid $mypid] } {
	    if { ! $DMN(silent) } {
		puts "Another daemon already watching $DMN(program) at $mypid"
	    }
	    exit 1
	}
	# Get the list of running processes for this program and
	# (re)start them if necessary.
	set pids [running]
	if { [llength $pids] > 0 } {
	    # One or (usually) more processes are running for that
	    # program (the program itself and the logger).  Check
	    # whether they need to be restarted and restart if
	    # necessary.
	    set pids [check_for_restart $pids]
	} else {
	    # There are no process already associated to this program,
	    # execute and be sure to bypass the lock file.
	    set pids [execute 1]
	}
    } else {
	# If we were not started with the -force option, we simply go
	# and try to execute the program.  This will fail nicely if
	# the lockfile exists.
	set pids [execute]
    }

    # If we were started with the watch option, see to periodically
    # watch for the existence of the processes that have been
    # associated to this program (and to restart them if necessary).
    # Remember our own process identifier in another pidfile so that
    # further instances of daemon.tcl can detect this one and not
    # interfer with us (or do when started with the -kill option)
    if { $DMN(watch) } {
	after $DMN(period) check_for_restart [list $pids] $DMN(period)
	set fd [open $mylock w]
	puts $fd [pid]
	close $fd
	vwait DMN(finish)
    }
}
