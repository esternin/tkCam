#!/bin/bash
# the next line restarts using undroidwish\
exec /usr/local/softdist/vanillawish "$0" -sdlrootheight 720 -sdlrootwidth 1280 -sdlheight 720 -sdlwidth 1280 -sdlresizable "$@"

# Requires these source codes
#   http://www.androwish.org/download/androwish-a03343f4cf.tar.gz
# With this patch for v4l2.c for proper exposure control
#   http://www.androwish.org/index.html/artifact/f155da6fa5a18e7e

# Written by E.Sternin, as proof of concept, but proved more reliable than "cheese"
# 2017.04.11 - initial release
# 2018.01.13 - exposure controls moved from external v4l2-ctl to internal v4l2 (only in undroidwish/vanillawish)
# 2020.06.19 - snapshot & save, hide the settings panel, minor clean-up
# 2022.11.01 - ffmpeg-based save of a clip of video stream
# 2022.11.04 - replace button graphics with UTF-8 symbols, balloon help, high-DPI font sizes

set APPNAME [lindex [file split [info script]] end]
set PLATFORM [lindex [array get tcl_platform os] 1]
set VERSION 2022.11.04
set DEBUG 0

package require Tk
package require v4l2
package require BWidget

### for high-density displays, rescale to look similar to what a 72dpi would be
set dpi [winfo fpixels . 1i]
set factor [expr $dpi / 72.0]
if ($DEBUG) {puts "Scaling everything by $factor"}
foreach font [font names] {
  font configure $font -size [expr round($factor * [font configure $font -size])]
  }
tk scaling -displayof . $factor

proc scaleImage {im xfactor {yfactor 0}} {
   set mode -subsample
   if {abs($xfactor) < 1} {
       set xfactor [expr 1./$xfactor]
   } elseif {$xfactor>=0 && $yfactor>=0} {
       set mode -zoom
   }
   set xfactor [expr round($xfactor)]
   if {$yfactor == 0} {set yfactor $xfactor}
   set t [image create photo]
   $t copy $im
   $im blank
   $im copy $t -shrink $mode $xfactor $yfactor
   image delete $t
   }

image create photo button_exit -data {
   R0lGODdhEQAQAPEAAAAAADAwMHV1df///ywAAAAAEQAQAAACOJyPqcsK0ByMYz4zVbgcBCVc
   lQUIyWaORvghoopl8fG+BjoPbBLKcYrYlFaPluaB9EQEwgCQwigAADs=
   }
scaleImage button_exit $factor
image create photo button_attach -data {
   R0lGODdhEAAQAPMAAAAAANzc3MPDw4CAgFhYWKCgoMDAAP//////AEBAAAAAAAAAAAAAAAAA
   AAAAAAAAACwAAAAAEAAQAAAEPhDISau9OGuAzJZdkh0CZ4jYEQQlalKDsLJTSBHxXNo3Lq+t
   C0GQYxVGhVwylcQ1L4cjADcgQKUSgvWC/UQAADs=
   }
scaleImage button_attach $factor
image create photo button_detach -data {
   R0lGODdhEAAQAPIAAAAAANzc3P///6CgoMPDw4CAgFhYWDAwMCwAAAAAEAAQAAADSQi6zDIt
   qieFXTSKwAXI0sAFwlERitiZDoceKskUxIgC6q0YtA3AhALDwKu5FAVDwxA0EiBKzaA3lXym
   PGwFAuAlt8NohGttJAAAOw==
   }
scaleImage button_detach $factor
image create photo button_settings -data {
   iVBORw0KGgoAAAANSUhEUgAAABAAAAAQCAMAAAAoLQ9TAAAABGdBTUEAALGPC/xhBQAAAJlQ
   TFRFFhYWFxcXGBgYHR0dHh4eHx8fIiIiIyMjJiYmNTU1NjY2Nzc3Pj4+Pz8/QEBAQ0NDS0tL
   ZGRkaGhoaWlpampqdXV1dnZ2gYGBgoKChYWFhoaGkpKSmZmZrKysra2tsrKyv7+/2dnZ2tra
   29vb4eHh4uLi5ubm7+/v8/Pz9vb29/f3+Pj4+fn5+vr6+/v7/Pz8/f39/v7+////pPMQPgAA
   AD10RVh0U29mdHdhcmUAWFYgdmVyc2lvbiAzLjEwYS1qdW1ib0ZpeCtFbmggb2YgMjAwODEy
   MTYgKGludGVyaW0hKbDgfIEAAACrSURBVBjTXY/pDoJADISXwxVE5ZJLQFhUQJBj5/0fzuUy
   xv5omknb+YZgqqGvqn6YRwLwfkQkyxHGnk+CaIjJ7UZiMXAQjsQ7mRmQmUcvASdg1AqBugZC
   izJxYhvAy6HUaQDDFgJTcjiHe6G7yJVpo9XKTn0CD7UrtfZX2AnhvZ64esH0C3K1WJ82zp66
   36fUChbbYLYVYP4KdvZnsAU9TTf0NZwkXbdwf/E/9bEjrraQk/4AAAAHdElNRQfkBhQDDinP
   Tc3nAAAAAElFTkSuQmCC
   }
scaleImage button_settings $factor

### alternatives in UTF8
set char_bullseye \u25CE
set char_fisheye  \u25C9
set char_play     \u25B6
set char_record   \u2B24
set char_power    \u23FB
set char_gear     \u2699
set char_cross    \u274C

proc SetStatus { state message } {
   global .status.led .status.text
   if { $state == "ok" } {
     .status.led configure -background green
   } elseif { $state == "error" } {
     .status.led configure -background red
   } elseif { $state == "warning" } {
     .status.led configure -background yellow
   } else {
     .status.led configure -background white
     }
   .status.text configure -text "$message"
   }

proc updateCameraList {op dev} {
   global vd Vdev
   # device list changed, update it no matter what
   #
   set DeviceList [lsort [v4l2 devices]]
   foreach d $DeviceList {
     if {![catch {set v [v4l2 open $d {}]}]} {
       v4l2 close $v
       } \
     else {
       # remove non-compliant v4l2 devices from the list
       set i [lsearch $DeviceList $d]
       set DeviceList [lreplace $DeviceList $i $i]
       }
     }
   .tbar.vdev configure -values $DeviceList

   if {$op == "remove"} {
     if {$Vdev == $dev} {
	# unplugged the currently selected device, stop and re-init
        InitVideo ""
        # the new choice is the first on the updated list
        set Vdev [lindex $DeviceList 0]
	}
     # else removed another, inactive device
     # etheir way, if the list now has only one device, connect to it
     if { [llength $DeviceList] == 1 } { InitVideo $Vdev }
     } \
   else {
     # else, $op == "add" 
     if {$vd == ""} {
	# no open device, choose the new one, likely the LAST one on the updated list
	set Vdev [lindex [lreverse $DeviceList] 0]
	if { [llength $DeviceList] == 1 } { InitVideo $Vdev }
	}
     # else we have a device connected, nothing to do
     }
   }

proc InitVideo {device} {
   global vd Vdev frame frate exp p char_bullseye char_fisheye
   if {"$device" == ""} {
     if {$vd != ""} {v4l2 close $vd; set vd ""}
     #.tbar.connect configure -image button_attach -command {InitVideo $Vdev}
     .tbar.connect configure -text "$char_bullseye" -foreground "#444444" -command {InitVideo $Vdev}
     .tbar.b configure -text "No camera"
     .tbar.clip configure -state disabled
     SetStatus "ok" "Disconnected from the camera"
     return
     }
   if {![catch {set vd [v4l2 open $device [list imagecb .tbar.b [.main.img cget -image]]]}]} { 
     .tbar.b configure -text "Preview"
     .tbar.clip configure -state normal
     #.tbar.connect configure -image button_detach -command {InitVideo ""} 
     .tbar.connect configure -text "$char_fisheye" -foreground "#00ff00" -command {InitVideo ""} 
     array set p [v4l2 parameters $vd]
     .tbar.frame configure -values [split [lindex [array get p frame-size-values] 1] ","]
     set FrameSizeMsg ""; set FrameRateMsg ""; set ExposureMsg "";
     if {![catch {set frame [lindex [array get p frame-size] 1]}]} {
       set FrameSizeMsg [format ", %s" [SetFrameSize]]
       }
     if {![catch {set frate $p(frame-rate)}]} {
       set FrameRateMsg [format " @ %s fps" [SetFrameRate]]
       .tbar.frate configure -from $p(frame-rate-minimum) -to $p(frame-rate-maximum) -increment $p(frame-rate-step)
       }
#    set exp_mode [lindex [exec v4l2-ctl --device=$Vdev --get-ctrl=exposure_auto] 1]
     if {![catch {set exp_mode $p(exposure-auto)}]} {
       if {$exp_mode == "manual-mode"} { 
#        set exp [lindex [exec v4l2-ctl --device=$Vdev --get-ctrl=exposure_absolute] 1]
         set exp $p(exposure-absolute)
         } \
       else {
         set exp "auto"
         }
       set ExposureMsg [format ", exposure: %s" [SetExposureTime]]
       .tbar.exp configure -from $p(exposure-absolute-minimum) -to $p(exposure-absolute-maximum) -increment $p(exposure-absolute-step)
       }
     GetParams  ;# refresh to the latest settings, we may have changed things
     SetStatus "ok" "Connected to $device$FrameSizeMsg$FrameRateMsg$ExposureMsg"
     } \
   else {
     SetStatus "warning" "Could not open $device"
     }
   }

proc SetFrameSize {} {
   global vd frame
   if {"$vd" == "" } { return } 
   if {"$frame" == "" } { return } 
   foreach {fw fh} [split $frame x] break
   .main.img configure -width $fw -height $fh
   if {[v4l2 state $vd] eq "capture"} { 
     v4l2 stop $vd
     v4l2 parameters $vd "frame-size" "$frame"
     v4l2 start $vd
     } \
   else {
     v4l2 parameters $vd "frame-size" "$frame"
     }
   SetStatus "ok" "Set frame size to $frame"
   return "$frame"
   }	

proc SetFrameRate {} {
   global vd frate
   if {"$vd" == "" } { return } 
   if {"$frate" == "" } { return } 
   if {[v4l2 state $vd] eq "capture"} { 
     v4l2 stop $vd
     v4l2 parameters $vd "frame-rate" "$frate"
     v4l2 start $vd
     } \
   else {
     v4l2 parameters $vd "frame-rate" "$frate"
     }
   SetStatus "ok" "Set frame rate to $frate fps"
   return "$frate"
   }	

proc SetExposureTime {} {
   global Vdev vd exp p
   if {"$vd" == "" } { return } 
   if {"$exp" == ""} { 
     return
     } \
   elseif {"$exp" == "auto"} {
     v4l2 parameters $vd "exposure-auto" "aperture-priority-mode"
#     exec v4l2-ctl --device=$Vdev --set-ctrl=exposure_auto=3
     } \
   else {
#     exec v4l2-ctl --device=$Vdev --set-ctrl=exposure_auto=1,exposure_absolute=$exp
     if {"$exp" == "default"} { set exp $p(exposure-absolute-default) }
     v4l2 parameters $vd "exposure-auto" "manual-mode"
     v4l2 parameters $vd "exposure-absolute" "$exp"
     }
   array set p [v4l2 parameters $vd]
   SetStatus "ok" "Set exposure to $p(exposure-auto) $p(exposure-absolute)"
   return "$p(exposure-auto) $p(exposure-absolute)"
   }

proc GetParams {} {
   global vd searchString
   if {$vd eq ""} { return }
   
   .main.params.bot.text delete 0.0 end
   .main.params.bot.text insert end "Current camera settings:\n"
   array set p [v4l2 parameters $vd]
   set names [lsort [array names p]]
   foreach name $names {
     .main.params.bot.text insert end [format "%s\n" [array get p $name]]
     }
   if {"$searchString" != ""} {textSearch .main.params.bot.text $searchString search}
   }

# callback: image ready or error
proc imagecb {button img dev ind} {
    if {$ind eq "error"} {
	$button configure -text "Preview"
    } else {
	v4l2 image $dev $img
    }
}

# toggle the left frame (settings) on/off
proc ToggleSettings {} {
    global show_settings
    if {$show_settings == 1} {
        pack forget .main.params 
        set show_settings 0
    } else {
	pack .main.img .main.params -side left
        set show_settings 1
    }
}

# highlight strings of interest in the params window
proc textSearch {w string tag} {
  # Remove all tags
  $w tag remove search 0.0 end
  # If string empty, do nothing
  if {$string == ""} {return}
  # Current position of 'cursor' at first line, before any character
  set cur 1.0
  # Search through the file, for each matching word, apply the tag 'search'
  while 1 {
    set cur [$w search -count length $string $cur end]
    if {$cur eq ""} {break}
    $w tag add $tag $cur "$cur + $length char"
    set cur [$w index "$cur + $length char"]
  }
  # For all the tagged text, apply the below settings
  .main.params.bot.text tag configure search -background green -foreground white
}

# button handler: start/stop image capture
proc startstop {button} {
    global vd
    if {$vd eq ""} { return }
    switch -glob -- [v4l2 state $vd] {
      capture {
	v4l2 stop  $vd
	$button configure -text "Preview" 
	SetStatus "ok" "[v4l2 counters $vd] frames received/processed"
	}
      stopped {
	v4l2 start $vd
	$button configure -text "Stop" 
        SetStatus "ok" "Preview active"
	}
      * {
        SetStatus "warning" "Don't know how to handle state = [v4l2 state $vd]"
        }
      }
    GetParams
}

proc CaptureClip {button duration} {
    global vd Vdev
    if {$Vdev eq ""} { return }
    set v_state [v4l2 state $vd]
    if {$v_state eq "capture"} {v4l2 stop $vd}
    set fn [tk_getOpenFile -filetypes { {{video} {.mp4 .mkv}} {{All Files} *} }]
    if { $fn != "" } {
      $button configure -state disabled
      set clip_err [catch {exec ffmpeg -v error -f v4l2 -framerate 30 \
        -video_size 640x480 -t $duration -i $Vdev -an $fn -y -map 0:v \
        -pix_fmt yuv420p -f xv "Capturing a $duration-s clip" }]
      $button configure -state normal
      if {$clip_err} {SetStatus "warning" "ffmpeg reported errors writing to $fn"} \
      else           {SetStatus "ok" "5s of video saved in $fn"}
      } \
    else {
      SetStatus "ok" "Clip capture aborted by user"
      }
    if {$v_state eq "capture"} {v4l2 start $vd}
}

proc changemirror {w} {
    global vd
    if {$vd ne ""} {
	lassign [v4l2 mirror $vd] x y
	set n [expr {$x + $y * 2 + 1}]
	v4l2 mirror $vd [expr {$n & 1}] [expr {$n & 2}]
    }
}

# capture and save snapshot of the current screen
proc snapshot {} {
    global vd 
    image create photo snapshot_img
    v4l2 image $vd snapshot_img
    
    set types {{"Image files" {.png}}}
    set time_stamp [clock format [clock seconds] -format {%Y%m%H%S}]
    set filename [tk_getSaveFile -filetypes $types -initialfile [format "Snapshot-%s.png" $time_stamp] -defaultextension .png]

    if {[llength $filename]} {
       snapshot_img write -format png $filename
       SetStatus "ok" "Snapshot saved in $filename"
       } \
    else {
       SetStatus "ok" "Snapshot saving cancelled"
   }
   image delete snapshot_img
}

wm geometry . "+0+0"; wm title . "USB Camera Control ($APPNAME,$PLATFORM) v.$VERSION"
#wm attributes . -fullscreen 1

set DeviceList [lsort [v4l2 devices]]
foreach d $DeviceList {
  if {![catch {set v [v4l2 open $d {}]}]} {
    v4l2 close $v
    } \
  else {
    # remove non-compliant v4l2 devices from the list
    set i [lsearch $DeviceList $d]
    set DeviceList [lreplace $DeviceList $i $i]
    }
  }
set vd ""
set Vdev [lindex $DeviceList 0]
set show_settings 0

frame  .tbar -relief raised -borderwidth 1
ComboBox .tbar.vdev -textvariable Vdev -width 12 -values $DeviceList -modifycmd {after 0 {SetStatus "ok" "Camera $Vdev selected"}}
#button .tbar.connect -image button_attach -command {InitVideo $Vdev}
Button .tbar.connect -text "$char_bullseye" -foreground "#444444" -command {InitVideo $Vdev} \
  -helptext "Connect with the selected camera" -helptype balloon 
#button .tbar.settings -image button_settings -command {ToggleSettings}
Button .tbar.settings -text "$char_gear" -command {ToggleSettings} \
  -helptext "Review camera settings" -helptype balloon
button .tbar.b -command [list startstop .tbar.b] -text "No camera"
Button .tbar.clip -command { CaptureClip .tbar.clip 5 } -text "$char_record" -foreground "#dd0000" \
  -helptext "Record a 5-s clip, using ffmpeg" -helptype balloon -state disabled
#button .tbar.snap -command { snapshot } -text "Snapshot"
#button .tbar.exit -image button_exit -command { exit }
#button .tbar.exit -text "$char_power" -command { exit }
Button .tbar.exit -text "$char_cross" -foreground "#dd0000" -command { exit } \
  -helptext "Terminate the program" -helptype balloon

frame .main -relief raised -borderwidth 1
label .main.img -image [image create photo -width 640 -height 480]

frame .main.params
frame .main.params.bot 
text  .main.params.bot.text -yscrollcommand ".main.params.bot.scroll set" -setgrid true
scrollbar .main.params.bot.scroll -command ".main.params.bot.text yview"
frame .main.params.top
button .main.params.top.refresh -text "Refresh" -command "GetParams"
entry .main.params.top.entry -width 25 -textvariable searchString
set searchString "exposure"
button .main.params.top.button -text "Find" -command "textSearch .main.params.bot.text \$searchString search"

frame .status
label .status.led  -text "" -background green -width 2
label .status.text -text "Ready. While running, left-click to rotate, right-click to clear"

ComboBox .tbar.frame -textvariable frame -width 10 -modifycmd {SetFrameSize}
set frame ""

spinbox .tbar.frate -width 5 -textvariable frate -command {SetFrameRate}
bind .tbar.frate <Leave> {SetFrameRate}
label .tbar.lab -text "fps | exposure:"
bind .tbar.frate <Return> {SetFrameRate}
set frate ""

spinbox .tbar.exp -width 5 -textvariable exp -command {SetExposureTime}
bind .tbar.exp <Leave> {SetExposureTime}
bind .tbar.exp <Return> {SetExposureTime}
set exp ""


if { [llength $DeviceList] == 1 } {
   # only one device available, try to initialize it
   InitVideo $Vdev
   }

pack .tbar -side top -fill x
#pack .tbar.connect .tbar.vdev .tbar.settings .tbar.frame .tbar.frate .tbar.lab .tbar.exp .tbar.b .tbar.snap -side left
pack .tbar.connect .tbar.vdev .tbar.frame .tbar.frate .tbar.lab .tbar.exp .tbar.b .tbar.clip -side left
pack .tbar.exit .tbar.settings -side right
pack .status -side bottom -fill x
pack .status.led .status.text -side left

#pack .main.params .main.img -side right

pack .main.img -side left
pack .main.params.top -side top
pack .main.params.bot -side top -expand yes -fill y
pack .main.params.top.refresh -side left -pady 5 -padx 10
pack .main.params.top.entry -side left
pack .main.params.top.button -side left -pady 5 -padx 10
pack .main.params.bot.text -side left -expand yes -fill y
.main.params.bot.text configure -width 50 -height 30
pack .main.params.bot.scroll -side right -fill y
bind .main.params.top.entry <Return> "textSearch .main.params.bot.text \$searchString search"

pack .tbar .main -side top
pack .status -side bottom

bind .main.img <1> {changemirror %W}
bind .main.img <3> {snapshot}

#bind .l <1> {changemirror %W}
#bind .l <3> {changeorientation %W}
#bind .main.img <3> {set i [.main.img cget -image]; $i blank}

# watch for (un)plugged devices
v4l2 listen updateCameraList
# try to init device
#init .tbar.b [.l cget -image]

