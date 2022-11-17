#!/bin/bash
# the next line restarts using undroidwish or vanillawish\
exec /usr/local/bin/vanillawish "$0" -sdlresizable "$@"

# Written by E.Sternin, as proof of concept, but proved more reliable than "cheese"
# 2017.04.11 - initial release
# 2018.01.13 - exposure controls moved from external v4l2-ctl to internal v4l2
# 2020.06.19 - snapshot & save, hide the settings panel, minor clean-up
# 2022.11.01 - ffmpeg-based save of a clip of video stream
# 2022.11.04 - replace button graphics with UTF-8 symbols, balloon help, high-DPI font sizes
# 2022.11.05 - canvas resize bug, basic help, cameras with missing controls
# 2022.11.12 - switch v4l2 -> tcluvc, record/stop for unlimited recording
# 2022.11.14 - catch failed parameter setting; frame rate adjusted on format change
# 2022.11.15 - cosmetic improvements, auto-save option on clip capture for instant recording

set APPNAME [lindex [file split [info script]] end]
set PLATFORM [lindex [array get tcl_platform os] 1]
set VERSION 2022.11.15
set DEBUG 0
set MINW  640
set MINH  360

# these are all built-in
package require Tk
package require tcluvc;	# this is ONLY available in undroidwish/vanillawish
package require BWidget

# do a dummy file load, to import the ::dialog:: space, change these tkfbox settings
# from the system-wide defaults, typically in /usr/share/tk8.5/tkfbox.tcl
catch {tk_getOpenFile foo bar}
set ::tk::dialog::file::showHiddenBtn 1
set ::tk::dialog::file::showHiddenVar 0

### for high-density displays, rescale to look similar to what a 72dpi would be
set dpi [winfo fpixels . 1i]
set factor [expr $dpi / 72.0]
if ($::DEBUG) {puts "Scaling everything by $factor"}
foreach font [font names] {
  font configure $font -size [expr round($factor * [font configure $font -size])]
  }
tk scaling -displayof . $factor

### special characters in UTF8, will scale properly on high-DPI displays
set char_bullseye \u25CE;	# "disconnected" state, empty middle, or \u2205=empty set
set char_fisheye  \u25C9;	# "connected" state, filled middle/
set char_play     \u25B6;	# right-pointing triangle
set char_record   \u25CF;	# filled circle, big one = \u2B24
set char_disk     \u26C1;	# ⛁ (white drafts king), or \u26B6 = ⚶ (vesta)
set char_stop     \u25A0;	# filled square, big one = \u2B1B
set char_power    \u23FB;	# power switch, may not be available (new)
set char_gear     \u2699;	# settings "wheel"
set char_cross    \u274C;	# big cross for exit, or \u2716
set char_reload   \u21BB;	# or use \u2B6E = clockwise gapped/open circle arrow

set help "
USB cameras (webcams) vary, in the settings ($char_gear), the range of frame sizes and rates, the video pixel formats, etc.

Select a camera of your choice and toggle connect ($char_bullseye); it is safer to disconnect a connected ($char_fisheye) camera before selecting another.

Use \[Preview\] to connect to the video stream and adjust parameters to the desired values, clicking or entering numbers directly. One can type \"reset\" or \"auto\" instead of a number into exposure field. Invalid numbers will be ignored. Valid ranges can be found under the settings menu ($char_gear) where everything is read-only.

Left-click inside the video frame will capture a snapshot; right-click will cycle through mirroring options.

If a control is greyed out, it's not available for this camera.

Once satisfied with the settings, use record/stop buttons ($char_record/$char_stop) to capture a video clip.
"

proc SetStatus { state message } {
  global .status.led .status.text
  switch -- $state {
    ok      { .status.led configure -background green }
    warning { .status.led configure -background yellow }
    error   { .status.led configure -background red }
    record  { .status.led configure -background orange }
    default { .status.led configure -background grey }
    }
  .status.text configure -text "$message"
  }

# On Linux, a udev rule needs to be added allowing for detaching the
# kernel driver from the device. Users must be in the `plugdev` group
# in order to be able to open the camera's USB device.
# An example `99-libuvc.rules` file is
#   #libuvc: enable users in group "plugdev" to detach the uvcvideo kernel driver
#   ACTION=="add", SUBSYSTEM=="usb", ENV{ID_USB_INTERFACES}=="*:0e02??:*", GROUP="plugdev"

proc findCameras {} {
  global DeviceMap
  set DeviceMap [dict create]
  foreach vd [uvc info] { uvc close $vd }
  set uvc_list [uvc devices]
  set l 0
  while {$l < [llength $uvc_list]} {
    set uvc_id   [lindex $uvc_list $l] ; incr l 2
    set usb_code [lindex [split $uvc_id :] 2]
    set uvc_name [lindex $uvc_list $l] ; incr l
    if {![catch {set v [uvc open $uvc_id {}]}]} {
      uvc close $v; 
      dict set DeviceMap $uvc_name-$usb_code $uvc_id
      } \
    else {
      puts "error accessing USB device $uvc_id; check udev rules/is user in plugdev?"
      }
    }
  return [dict keys $DeviceMap]
  }

proc updateCameraList {op dev} {
  global vd Vdev
  # device map changed, update it no matter what
  #
  set DeviceList [findCameras]
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
  global DeviceMap vd Vdev fMap AvailableFormats frame frate exp p
  if {"$device" == ""} {
    if {$vd != ""} {uvc close $vd; set vd ""}
    .tbar.connect configure -text "$::char_bullseye" -foreground "#444444" -command {InitVideo $Vdev}
    .tbar.b configure -text "No camera"
    .tbar.clip configure -state disabled
    SetStatus "ok" "Disconnected from the camera"
    return
    }
  if { [catch {set vd [uvc open [dict get $DeviceMap $device] imagecb]} ] } {
    SetStatus "warning" "Could not open $device"
    return
    }
    
  .tbar.b configure -text "Preview"
  .tbar.clip configure -state normal 
  .tbar.connect configure -text "$::char_fisheye" -foreground "#00ff00" -command {InitVideo ""} 

  ### connected to a device, but does it have video streams?
  .tbar.frame configure -state disabled
  .tbar.frate configure -state disabled
  if {![catch {set AvailableFormats [uvc listformats $vd]}]} {
    ### establish short names for all available formats, fMap maps these onto the video format index
    set fMap [dict create]
    set formats [lsort [dict keys $AvailableFormats]]
    foreach i $formats {
      set f [dict get $AvailableFormats $i]
      set frameSize [dict get $f frame-size]
      set frameRate [dict get $f frame-rate]
      dict set fMap $frameSize@$frameRate $i
      }
    ### current camera format
    if {![catch {lassign [uvc format $vd] i frate}]} {
      set f [dict get $AvailableFormats $i]
      set frameSize [dict get $f frame-size]
      set frame $frameSize@$frate
      set FrameMsg ", $frame"
      SetFrameSize
      .tbar.frame configure -state normal -values [dict keys $fMap]
      .tbar.frate configure -state normal -values [dict get $f frame-rate-values]
      GetParams  ;# refresh the parameter set to the current camera
      if ($::DEBUG) { parray p } 
      }\
    else {
      set frame ""; set frate ""; set FrameMsg ", unknown format"; set p ""
      }
    }\
  else {
    SetStatus "warning" "Camera reports no video formats"
    return  
    }

  ### do we have exposure control in the parameters of the camera?  
  if {[catch {set exp "$p(exposure-time-abs)"}]} {
    .tbar.exp configure -state disabled -command {}
    bind .tbar.exp <Leave> {}
    bind .tbar.exp <Return> {}
    set ExposureMsg ""
    }\
  else {
    .tbar.exp configure -state normal -from $p(exposure-time-abs-minimum) \
      -to $p(exposure-time-abs-maximum) -increment $p(exposure-time-abs-step) \
      -command {SetExposureTime}
    bind .tbar.exp <Leave> {SetExposureTime}
    bind .tbar.exp <Return> {SetExposureTime}
    set ExposureMsg ", exposure: $exp"
    }
  SetStatus "ok" "Connected to $device$FrameMsg$ExposureMsg"
  }

# callback: image ready
proc imagecb {vd} {
  uvc image $vd [.main.img cget -image]
  }

proc SetFrameSize {} {
  global Vdev vd fMap AvailableFormats frame frate
  set frame [.tbar.frame get]
  ### changing frame size may affect the frame rate  
  set frate [lindex [split $frame @] 1]
  if ($::DEBUG) { puts "SetFrameSize: on entry value = $frame" }
  if {"$vd" == "" } { return } 
  if {"$frame" == "" } { return }
  set vd_state [uvc state $vd]
  ### if streaming, stop first
  if {$vd_state eq "capture"} { uvc stop $vd }

  set i [dict get $fMap $frame]
  if ($::DEBUG) { puts "SetFrameSize: $frame --> $i" }
  set f [dict get $AvailableFormats $i]
  .tbar.frame configure -state normal -values [dict keys $fMap]
  .tbar.frate configure -state normal -values [dict get $f frame-rate-values]
  set frameSize [dict get $f frame-size]
  foreach {fw fh} [split $frameSize x] break
  [.main.img cget -image] configure -width $fw -height $fh
  ### set, but then read back
  uvc format $vd $i $frate
  lassign [uvc format $vd] i frate
  set frame $frameSize@$frate

  ### if were streaming, re-start
  if {$vd_state eq "capture"} { after 500; uvc start $vd }

  uvc image $vd [.main.img cget -image]
  .main.params configure -height $fh
  SetStatus "ok" "Set frame size to $frame"
  }	

proc SetFrameRate {} {
  global vd fMap AvailableFormats frame frate
  if {"$vd" == "" } { return } 
  if {"$frate" == "" } { return } 
  set vd_state [uvc state $vd]
  ### if streaming, stop first
  if {$vd_state eq "capture"} { uvc stop $vd }

  set i [dict get $fMap $frame]
  uvc format $vd $i $frate
  lassign [uvc format $vd] i frate
  set frameSize [dict get [dict get $AvailableFormats $i] frame-size]

  ### if were streaming, re-start
  if {$vd_state eq "capture"} { after 500; uvc start $vd }
  SetStatus "ok" "Set frame rate to $frate fps"
  }	

proc SetExposureTime {} {
  global Vdev vd exp p
  if ($::DEBUG) { puts "SetExposureTime: on entry exp = $exp" }
  if {"$vd" == "" } { return }
  if {"$exp" == ""} { return }
  if {"$exp" == "reset"} { set exp $p(exposure-time-abs-default) }

  if {"$exp" == "auto"}  {
    set err [catch {array set p [uvc parameters $vd ae-mode 8]}]
    } \
  else {
    set err [catch {array set p [uvc parameters $vd ae-mode 1 exposure-time-abs $exp]}]
    }
  after 100
  UpdateParams
  if ($err) { SetStatus "warning" "Changing exposure mode/time did not work" }\
  else      { SetStatus "ok"      "Set ae-mode to $p(ae-mode) ($p(exposure-time-abs))" }
  return $p(exposure-time-abs)
  }

proc GetParams {} {
  global vd frate frame p
  if {$vd eq ""} { return }
  array set p [uvc parameters $vd]
  UpdateParams
  }

proc UpdateParams {} {
  global frame frate p searchString
  if {[.tbar.exp configure -state] eq "normal"} { set exp $p(exposure-time-abs) }  
  .main.params.bot.text delete 0.0 end
  if {[array size p] > 0} {
    foreach name [lsort [array names p]] {
      .main.params.bot.text insert end [format "%s\n" [array get p $name]]
      }
    if {"$searchString" != ""} {textSearch .main.params.bot.text $searchString search}
    }\
  else {
    .main.params.bot.text insert end "Camera reports no parameters"
    }
  }

# toggle the left frame (settings) on/off
proc ToggleSettings {} {
  global show_settings frame
  if {$show_settings == 1} {
    pack forget .main.params 
    set show_settings 0
    } \
  else {
    pack .main.params -side right -fill y
    ### reset size and repack both widgets in params.bot, to match frame height
    .main.params.bot.text configure -height 1
    pack .main.params.bot.text   -side left  -expand yes -fill y
    pack .main.params.bot.scroll -side right -fill y
    set show_settings 1
    GetParams
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

# button handler: start/stop stream
proc startstop {button} {
  global vd Vdev
  if {$vd eq ""} { return }
  switch -glob -- [uvc state $vd] {
    capture {
      uvc stop  $vd
      $button configure -text "Preview" 
      SetStatus "ok" "[uvc counters $vd] frames received/processed"
      }
    stopped {
      InitVideo $Vdev 
      uvc start $vd
      $button configure -text "Stop" 
      SetStatus "ok" "Preview active"
      }
    * {
      SetStatus "warning" "Don't know how to handle state = [uvc state $vd]"
      }
    }
  GetParams
  } 

proc CaptureClip {button duration} {
  global vd Vdev frame frate
  if {$Vdev eq ""} { return }
  set rec_state [uvc record $vd state]
  if {$rec_state eq "recording"} {
    uvc record $vd stop
    $button configure -text "$::char_record" -foreground "#dd0000" -background "#d9d9d9"\
      -helptext "Start recording a clip" -helptype balloon
    SetStatus "ok" "Recording completed"
    }\
  else {
    set time_stamp [clock format [clock seconds] -format {%Y%m%d-%H%S}]
    set initfn [format "video-%s.avi" $time_stamp]
    if ($::autosave) {
      set fn $initfn
      }\
    else {
      set fn [ tk_getSaveFile -filetypes {{{video} {.avi}} {{All Files} *}} \
        -initialfile $initfn -defaultextension .avi ]
      }
    if { $fn != "" } {
     set rec_chan [open $fn w+]
      chan configure $rec_chan -encoding binary
      uvc record $vd start -chan $rec_chan -mjpeg
      $button configure -text "$::char_stop" -foreground "#000000" -background orange\
        -helptext "Stop recording a clip" -helptype balloon 
      SetStatus "record" "Recording a clip..."
      } \
    else {
      SetStatus "ok" "Clip recording aborted by user"
      }    
    }
  }

proc changemirror {w} {
  global vd
  if {$vd ne ""} {
    lassign [uvc mirror $vd] x y
    set n [expr {$x + $y * 2 + 1}]
    uvc mirror $vd [expr {$n & 1}] [expr {$n & 2}]
    }
  }

# capture and save snapshot of the current screen
proc snapshot {} {
  global vd 
  image create photo snapshot_img
  uvc image $vd snapshot_img
    
  set time_stamp [clock format [clock seconds] -format {%Y%m%d-%H%S}]
  set initfn [format "snapshot-%s.png" $time_stamp]
  if ($::autosave) {
    set fn $initfn
    }\
  else {
    set fn [tk_getSaveFile -filetypes {{"Image files" {.png}}} \
      -initialfile $initfn -defaultextension .png]
    }
  if {[llength $fn]} {
    snapshot_img write -format png $fn
    SetStatus "ok" "Snapshot saved in $fn"
    } \
  else {
    SetStatus "ok" "Snapshot saving cancelled"
    }
  image delete snapshot_img
  }

### top level: interactions with window manager
### place wm . close to the top left
set wmX [expr { (([winfo screenwidth  . ] - $MINW)/ 4) }]
set wmY [expr { (([winfo screenheight . ] - $MINH) / 4) }]
wm geometry . "+${wmX}+${wmY}"
wm title . "USB Camera Control ($APPNAME,$PLATFORM) v.$VERSION"
#wm attributes . -fullscreen 1
wm protocol . WM_DELETE_WINDOW {
  set answer [tk_messageBox -message "Quit $APPNAME?" -type yesno]
  if {$answer=="yes"} {exit}
}

set DeviceList [findCameras]
if ($::DEBUG) {foreach d $DeviceList {puts "$d --> [dict get $DeviceMap $d]"}}
set vd ""

set Vdev [lindex $DeviceList 0]
set show_settings 0

frame  .tbar -relief raised -borderwidth 1
ComboBox .tbar.vdev -textvariable Vdev -width 24 -values $DeviceList -modifycmd {after 0 {SetStatus "ok" "Camera $Vdev selected"}}
Button .tbar.connect -text "$char_bullseye" -foreground "#444444" -command {InitVideo $Vdev} \
  -helptext "Connect with the selected camera" -helptype balloon 
Button .tbar.settings -text "$char_gear" -command {ToggleSettings} \
  -helptext "Camera settings" -helptype balloon
button .tbar.b -command [list startstop .tbar.b] -text "No camera"
Button .tbar.clip -command { CaptureClip .tbar.clip 5 } -text "$char_record" -foreground "#dd0000" \
  -helptext "Start recording a clip" -helptype balloon -state disabled
checkbutton .tbar.autosave -text "$char_disk" -variable autosave 
DynamicHelp::register .tbar.autosave balloon "Save snapshots and clips to disk without asking for file names"
Button .tbar.exit -text "$char_cross" -foreground "#dd0000" -command { exit } \
  -helptext "Terminate the program" -helptype balloon
button .tbar.help -text "?" -width 1
.tbar.help configure -command { tk_messageBox -message "$APPNAME: basic usage" -detail $help  -type ok }
ComboBox .tbar.frame -textvariable frame -width 13 -modifycmd {SetFrameSize}
set frame ""
ComboBox .tbar.frate -textvariable frate -width 3 -modifycmd {SetFrameRate}
set frate ""
label .tbar.lab -text "fps | exposure:"
spinbox .tbar.exp -width 5 -textvariable exp -state disabled
set exp ""

frame .main -relief raised -borderwidth 1
label .main.img -image [image create photo -width $MINW -height $MINH]
DynamicHelp::register .main.img balloon "Left-click here to capture a snapshot; right-click to mirror"
frame .main.params
frame .main.params.bot 
text  .main.params.bot.text -yscrollcommand ".main.params.bot.scroll set" -setgrid true -width 35
scrollbar .main.params.bot.scroll -command ".main.params.bot.text yview"
frame .main.params.top
button .main.params.top.refresh -text "$char_reload" -command "GetParams"
entry .main.params.top.entry -width 20 -textvariable searchString
set searchString "exposure"
button .main.params.top.button -text "Find" -command "textSearch .main.params.bot.text \$searchString search"

frame .status
label .status.led  -text "" -background green -width 2
label .status.text -text "Ready. Connect to a camera from the selection list, then click \"Preview\""

# only one device available, try to initialize it
#if { [llength $DeviceList] == 1 } {InitVideo $Vdev}

pack .tbar -side top -fill x
pack .tbar.connect .tbar.vdev .tbar.frame .tbar.frate .tbar.lab .tbar.exp .tbar.b .tbar.clip .tbar.autosave -side left
pack .tbar.exit .tbar.settings .tbar.help -side right

pack .status -side bottom -fill x
pack .status.led .status.text -side left

pack .main.img -side left
pack .main.params -side right -fill y
pack .main.params.top -side top
pack .main.params.bot -side top -expand yes -fill y
pack .main.params.top.refresh -side left -pady 5 -padx 10
pack .main.params.top.entry -side left
pack .main.params.top.button -side left -pady 5 -padx 10
pack .main.params.bot.text -side left -expand yes -fill y
pack .main.params.bot.scroll -side right -fill y
bind .main.params.top.entry <Return> "textSearch .main.params.bot.text \$searchString search"
pack forget .main.params

pack .tbar .main -side top
pack .status -side bottom

bind .main.img <3> {changemirror %W}
bind .main.img <1> {snapshot}

# watch for (un)plugged devices
uvc listen updateCameraList
