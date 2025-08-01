#!/bin/bash
# the next line restarts using wish\
exec wish "$0" -sdlrootheight 720 -sdlrootwidth 1280 -sdlheight 720 -sdlwidth 1280 -sdlresizable "$@"

# Requires undroidwish or vanillawish, with v4l2 included
# Last downloaded 2025.07 from http://www.androwish.org/
#exec /usr/local/bin/vanillawish "$0" -sdlrootheight 720 -sdlrootwidth 1280 -sdlheight 720 -sdlwidth 1280 -sdlresizable "$@"

#### OR 
# the v4l2 library from https://androwish.org/home/finfo?name=undroid/v4l2/
# compiled and installed under the standard wish

# Written by E.Sternin, as a proof of concept, but seems more reliable than "cheese"
# 2017.04.11 - initial release
# 2018.01.13 - exposure controls moved from external v4l2-ctl to internal v4l2 (only in undroidwish/vanillawish)
# 2020.06.19 - snapshot & save, hide the settings panel, minor clean-up
# 2022.11.01 - ffmpeg-based save of a clip of video stream
# 2022.11.04 - replace button graphics with UTF-8 symbols, balloon help, high-DPI font sizes
# 2022.11.05 - canvas resize bug, basic help, cameras with missing controls
# 2022.11.12 - switch v4l2 -> tcluvc (fork out a version), record/stop for unlimited recording
# 2022.11.14 - catch failed parameter setting; frame rate adjusted on format change
# 2022.11.15 - cosmetic improvements, auto-save option on clip capture for instant recording
# 2022.11.17 - cosmetic improvements, filename missing minutes, extend autosave to snapshots
# 2025.07.27 - bugfix: match image and widget sizes when frame-size changes
# 2025.07.29 - switch to wish by default, as v4l2 can now be installed separately from undroidwish/vanillawish
# 2025.07.31 - blend the two versions, use whatever video library is available

set APPNAME [lindex [file split [info script]] end]
set PLATFORM [lindex [array get tcl_platform os] 1]
set VERSION 2025.07.31
set DEBUG 0
foreach arg $argv {
  if {"$arg"=="DEBUG"}  { set DEBUG 1 }
  }
if ($::DEBUG) {puts stderr "DEBUG: $APPNAME@$PLATFORM (v.$VERSION) invoked with DEBUG"}

if { [catch {package require Tk}] } {
  puts stderr "Tk package is missing, maybe `sudo apt-get install tk`\n"; exit 1
  }\
else {
  catch { tk_getOpenFile foo bar }
  if { [namespace exists ::tk::dialog] } {
    # some tcl/tk implementations do not implement ::tk::dialog
    # do a dummy file load, to import the ::dialog:: space, change these tkfbox settings
    # from the system-wide defaults, typically in /usr/share/tk8.5/tkfbox.tcl
    if ($::DEBUG) { puts stderr "DEBUG: changing the defaults settings for hidden files" }
    set ::tk::dialog::file::showHiddenBtn 1
    set ::tk::dialog::file::showHiddenVar 0
    }
  }
#### video support, can use v4l2 or uvc (preferred), both included in undroidwish
if { [catch {set vlversion [package require tcluvc]}] } {
  if { [catch {set vlversion [package require v4l2]}]} {
    puts stderr " video libraries (v4l2 and tcluvc) are missing, you must\n - use vanilla/undroidwish\n - install v4l2 from androwish.org/home/file/undroid/v4l2/\n - install libuvc and tcluvc from androwish.org/home/file/undroid/jni/tcluvc"; exit 1;
    }\
  else { set vlib "v4l2" }
  }\
else {   set vlib "uvc" }
if ($::DEBUG) { puts stderr "DEBUG: using $vlib v.$vlversion" }

#### BWidget extension
if { [catch {package require BWidget}] } {
  puts stderr "BWidget package is missing, use vanillawish/undroidwish or try \"sudo apt-get install bwidget\"\n"; exit 1
  }

### for high-density displays, rescale to look similar to what a 72dpi would be
set dpi [winfo fpixels . 1i]
set factor [expr $dpi / 72.0]
if ($::DEBUG) {puts stderr "DEBUG: scaling everything by $factor"}
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
USB cameras (webcams) vary. In the Settings tab ($char_gear), see the range of frame sizes and rates, the video pixel formats, etc.

Select a camera of your choice and toggle connect ($char_bullseye); it is safer to disconnect a connected ($char_fisheye) camera before selecting another.

Use \[Preview\] to connect to the video stream and adjust parameters to the desired values, clicking or entering numbers directly. One can type \"reset\" or \"auto\" instead of a number into exposure field. Invalid numbers will be ignored. Valid ranges can be found under the settings menu ($char_gear) where everything is read-only.

Left-click inside the video frame will capture a snapshot; right-click will cycle through mirroring options.

If a control is greyed out, it's not available for this camera.

Once satisfied with the settings, use record/stop buttons ($char_record/$char_stop) to capture a video clip. Without UVC support installed, recording is limited to 5-sec clips recorded using ffmpeg.
"
set MINW  640
set MINH  360

proc SetStatus { state message } {
  global .status.led .status.text
  switch -- $state {
    ok      { .status.led configure -background lightgreen }
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
  global vlib DeviceMap
  set DeviceMap [dict create]
  #foreach vd [uvc info] { uvc close $vd }
  set dev_list [$vlib devices]
  # uvc: "046D:0837:1.19 046d {BCC950 ConferenceCam} 045E:075D:1.17 Microsoft {Microsoft® LifeCam Cinema(TM)}
  # vlib: "/dev/video0 /dev/video2"
  if {"$vlib"=="v4l2"} { 
    foreach dev_id $dev_list {
      if {![catch {set v [$vlib open $dev_id {}]}]} {
        dict set DeviceMap $dev_id $dev_id
        $vlib close $v
        } \
      else {
        puts stderr "Error accessing v4l2 device $dev_id; check udev USB rules?"
        }
      }
    }\
  else {
    foreach {usb_code usb_name dev_id} $dev_list {
      puts $dev_id
      if {![catch {set v [$vlib open $dev_id {}]}]} {
        dict set DeviceMap $usb_name-$usb_code $dev_id
        $vlib close $v
        } \
      else {
        puts stderr "Error accessing USB device $dev_id; check udev rules/is user in plugdev?"
        }
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
  global DeviceMap vlib vd Vdev fMap AvailableFormats frame frate exp p
  if {"$device" == ""} {
    if {$vd != ""} {$vlib close $vd; set vd ""}
    .tbar.connect configure -text "$::char_bullseye" -foreground "#444444" -command {InitVideo $Vdev}
    .tbar.b configure -text "No camera"
    .tbar.clip configure -state disabled
    SetStatus "ok" "Disconnected from the camera"
    set frame ""; set frate ""; return
    }
  if { [catch {set vd [$vlib open [dict get $DeviceMap $device] imagecb]} ] } {
    SetStatus "warning" "Could not open $device"
    return
    }
  .tbar.b configure -text "Preview"
  .tbar.clip configure -state normal 
  .tbar.connect configure -text "$::char_fisheye" -foreground "#00ff00" -command {InitVideo ""} 
  ### connected to a device, but does it have video streams?
  .tbar.frame configure -state disabled
  .tbar.frate configure -state disabled
  if {"$vlib"=="v4l2"} {
    if {[catch {array set p [v4l2 parameters $vd]}]} { 
      SetStatus "warning" "Camera $device has no v4l2 controls"
      set frame ""; set frate ""; return
      }\
    else {    
      if ($::DEBUG) { puts stderr "DEBUG: v4l2 camera properties:"; parray p }
      set AvailableFormats [split [lindex [array get p frame-size-values] 1] ","]
      # 640x480@RGB3 1280x720@RGB3 960x544@RGB3
      set frameSizes {}
      foreach f $AvailableFormats {lappend frameSizes [lindex [split $f @] 0]}
      .tbar.frame configure -state normal -values [lsort -decreasing -unique $frameSizes]
      .tbar.frate configure -state normal -from $p(frame-rate-minimum) \
        -to $p(frame-rate-maximum) -increment $p(frame-rate-step)
      if {[catch {set frame $p(frame-size)}]} { set frame "" }
      if {[catch {set frate $p(frame-rate)}]} { set frate "" }           
      }
    }\
  else {
    if {[catch {set AvailableFormats [uvc listformats $vd]}]} { 
      SetStatus "warning" "Camera reports no uvc video formats"
      set frame ""; set frate ""; return
      }\
    else {
      ### establish short names for all available formats, fMap maps these onto the video format index
      set fMap [dict create]
      set formats [lsort [dict keys $AvailableFormats]]
      # 0 {frame-size 640x480 frame-rate 30 frame-rate-values {30 24 20 15 10 7 5} mjpeg 0}
      set frameSizes {}
      foreach i $formats {
        set f [dict get $AvailableFormats $i]
        set frameSize [dict get $f frame-size]
        set frameRate [dict get $f frame-rate]
        dict set fMap $frameSize@$frameRate $i
        lappend frameSizes $frameSize
        }
      if ($::DEBUG) { puts stderr "DEBUG: uvc camera properties:\n[dict keys $fMap]" }
      .tbar.frame configure -state normal -values [lsort -decreasing -unique $frameSizes] 
 
      ### current camera format
      if {![catch {lassign [uvc format $vd] i frate}]} {
        set f [dict get $AvailableFormats $i]
        .tbar.frate configure -state normal -values  [dict get $f frame-rate-values]
        set frameSize [dict get $f frame-size]
        set frame $frameSize
        }\
      else {
        set frame ""; set frate ""
        }
      } 
    }
  SetFrameSize
  GetParams
  if ($::DEBUG) {puts stderr "DEBUG: camera parameters are:"; parray p}
  if {"$vlib"=="v4l2" && ![catch {set exp_mode $p(auto-exposure)}]} {
    if {"$exp_mode"=="manual-mode"} { 
      set exp $p(exposure-time-absolute)
      .tbar.exp configure -state normal -from $p(exposure-time-absolute-minimum) \
        -to $p(exposure-time-absolute-maximum) -increment $p(exposure-time-absolute-step)          
      }\
    else { set exp "auto" }
    }\
  elseif {![catch {set exp_mode $p(ae-mode)}] } {
    if {"$exp_mode"=="1"} {
      set exp $p(exposure-time-abs)
      .tbar.exp configure -state normal -from $p(exposure-time-abs-minimum) \
        -to $p(exposure-time-abs-maximum) -increment $p(exposure-time-abs-step)          
      }\
    else { set exp "auto" }
    }
  .tbar.exp configure -state normal -command {SetExposureTime}
  bind .tbar.exp <Return> {SetExposureTime}
  SetStatus "ok" "Connected to $vlib device $device, $frame @ $frate fps"
  }

# callback: image ready
proc imagecb {vd args} {
  global vlib
  if {[llength args] < 1} { set ind [lindex $args 0] } else { set ind "" }
  if {$ind eq "error"} {$button configure -text "Preview"}\
  else                 {$vlib image $vd [.main.img cget -image]}
  }

# button handler: start/stop stream
proc startstop {button} {
  global vlib vd Vdev
  if {$vd eq ""} { return }
  switch -glob -- [$vlib state $vd] {
    capture {
      $vlib stop  $vd
      $button configure -text "Preview" 
      SetStatus "ok" "[$vlib counters $vd] frames received/processed"
      }
    stopped {
      InitVideo $Vdev 
      $vlib start $vd
      $button configure -text "Stop" 
      SetStatus "ok" "Preview active"
      }
    * {
      SetStatus "warning" "Don't know how to handle state = [$vlib state $vd]"
      }
    }
  GetParams
  } 

proc SetFrameSize {} {
  global vlib Vdev vd AvailableFormats fMap frame frate
  set frame [.tbar.frame get]
  if {"$vd" == "" } { return } 
  if {"$frame" == "" } { return }
  set vd_state [$vlib state $vd]
  ### if streaming, stop first
  if {$vd_state eq "capture"} { $vlib stop $vd }
  foreach {fw fh} [split $frame x] break
  [.main.img cget -image] configure -width $fw -height $fh
  if {"$vlib"=="v4l2"} { v4l2 parameters $vd frame-size $frame; v4l2 image $vd [.main.img cget -image]}\
  else                 { uvcSetFrame }
  ### if were streaming, re-start
  #$vlib image $vd [.main.img cget -image]
  if {$vd_state eq "capture"} { after 200; $vlib start $vd }
  .main.params configure -height $fh
  SetStatus "ok" "Set frame to $frame @ $frate fps"
  }	

proc SetFrameRate {} {
  global vlib vd fMap AvailableFormats frame frate
  if {"$vd" == "" } { return } 
  if {"$frate" == "" } { return } 
  set vd_state [$vlib state $vd]
  ### if streaming, stop first
  if {$vd_state eq "capture"} { $vlib stop $vd }
  if {"$vlib"=="v4l2"} { v4l2 parameters $vd frame-rate $frate }\
  else                 { uvcSetFrame }
  ### if were streaming, re-start
  if {$vd_state eq "capture"} { after 200; $vlib start $vd }
  SetStatus "ok" "Set frame to $frame @ $frate fps"
  }
  
proc uvcSetFrame {} {
  global vd fMap AvailableFormats frame frate

  if ($::DEBUG) { puts stderr "DEBUG: uvcSetFrame requesting $frame@$frate" }
  lassign [uvc format $vd] i frate_now
  set f [dict get $AvailableFormats $i]
  set frameSize [dict get $f frame-size]
  set frameRates [dict get $f frame-rate-values]
  ### if frame size is changing or the new frame rate is not valid for this format
  if {$frame!=$frameSize || [lsearch -exact $frameRates $frate] < 0} {
    if {[catch {set i [dict get $fMap $frame@$frate]}]} {
      ### if not the exact frame@frate, choose (the last) of the same frame size
      set i [lindex [dict filter $fMap key $frame*] end]
      set f [dict get $AvailableFormats $i]
      set frameRates [dict get $f frame-rate-values]
      }
    .tbar.frate configure -state normal -values $frameRates
    ### we requested is not a valid frame rate, set to the default (first) value
    if {[lsearch -exact $frameRates $frate] < 0} {set frate [lindex $frameRates 0]}
    if ($::DEBUG) { puts "uvcSetFrame: $i --> $f" }   
    }
  uvc format $vd $i $frate
  ### read back to confirm
  lassign [uvc format $vd] i frate
  }

proc SetExposureTime {} {
  global vlib Vdev vd exp p
  if ($::DEBUG) { puts "SetExposureTime: on entry exp = $exp" }
  if {"$vd" == "" } { return }
  if {"$exp" == ""} { return }

  if {"$vlib"=="v4l2"} {
    switch $exp {
      reset  {set err [catch \
        {v4l2 parameters $vd auto-exposure "manual-mode" exposure-time-absolute $p(exposure-time-absolute-default)}]}
      auto    {set err [catch \
        {v4l2 parameters $vd auto-exposure "aperture-priority-mode"}]}
      default {set err [catch \
        {v4l2 parameters $vd auto-exposure "manual-mode" exposure-time-absolute "$exp"}]}
      }    
    }\
  else {
    switch $exp {
      reset   {set err [catch \
        {uvc parameters $vd ae-mode 1 exposure-time-abs $p(exposure-time-abs-default)}]}
      auto    {set err [catch \
        {uvc parameters $vd ae-mode 8}]}
      default {set err [catch \
        {uvc parameters $vd ae-mode 1 exposure-time-abs $exp}]}  
      }    
    }
  after 100 
  GetParams  ;# refresh to the latest settings, we may have changed things
  if {"$vlib"=="v4l2"} { set str "$p(auto-exposure):$p(exposure-time-absolute)" }\
  else                 { set str "$p(ae-mode):$p(exposure-time-abs)" }
  if ($err) {SetStatus "warning" "Changing exposure to $str did not work"}\
  else      {SetStatus "ok" "Exposure change to $str"}
  }

proc GetParams {} {
  global vlib vd frate frame p
  if {$vd eq ""} { return }
  array set p [$vlib parameters $vd]
  UpdateParams
  }

proc UpdateParams {} {
  global vlib frame frate exp p searchString

  if {"$vlib"=="v4l2"} {if {"$p(auto-exposure)"=="manual-mode"} {set exp $p(exposure-time-absolute)} }\
  else                 {if {"$p(ae-mode)"==1}                   {set exp $p(exposure-time-abs)} }
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

proc CaptureClip {button duration} {
  global vlib vd Vdev frame frate
  if {$Vdev eq ""} { return }

  set time_stamp [clock format [clock seconds] -format {%Y%m%d-%H%M%S}]
  set initfn [format "video-%s.avi" $time_stamp]
  set fn $initfn

  if {"$vlib"=="v4l2"} {
    set v_state [v4l2 state $vd]
    if {$v_state eq "capture"} {v4l2 stop $vd}
    if (!$::autosave) {
      set fn [ tk_getSaveFile -filetypes {{{video} {.mp4 .mkv}} {{All Files} *}} \
          -initialfile $initfn -defaultextension .mp4 ]
      }
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
      SetStatus "ok" "v4l2 clip recording aborted by user"
      }
    if {$v_state eq "capture"} {v4l2 start $vd}
    }\
  else {   
    set rec_state [uvc record $vd state]
    if {$rec_state eq "recording"} {
      uvc record $vd stop
      $button configure -text "$::char_record" -foreground "#dd0000" -background "#d9d9d9"\
        -helptext "Start recording a clip" -helptype balloon
      SetStatus "ok" "Recording completed"
      }\
    else {
      if (!$::autosave) {
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
  }

proc changemirror {w} {
  global vlib vd
  if {$vd ne ""} {
    lassign [$vlib mirror $vd] x y
    set n [expr {$x + $y * 2 + 1}]
    $vlib mirror $vd [expr {$n & 1}] [expr {$n & 2}]
    }
  }

# capture and save snapshot of the current screen
proc snapshot {} {
  global vlib vd 
  image create photo snapshot_img
  $vlib image $vd snapshot_img
    
  set time_stamp [clock format [clock seconds] -format {%Y%m%d-%H%M%S}]
  set initfn [format "snapshot-%s.png" $time_stamp]
  if ($::autosave) {
    ### snapshots more frequent than once per sec will use the same filename, will overwrite
    set fn $initfn
    }\
  else {
    set fn [tk_getSaveFile -filetypes {{{image} {.png}} {{All Files} *}} \
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
if ($::DEBUG) {
  foreach d $DeviceList {
    if {"$vlib"=="uvc"} {puts stderr "DEBUG: $d --> [dict get $DeviceMap $d]"}\
    else {puts stderr "DEBUG: $d (v4l2 device)"}
    }
  }
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
  -helptext [expr {"$vlib"=="v4l2" ? "Record a 5-s clip with ffmpeg" : "Start recording a clip"}] \
  -helptype balloon -state disabled
checkbutton .tbar.autosave -text "$char_disk" -variable autosave 
DynamicHelp::register .tbar.autosave balloon "Save snapshots and clips to disk without asking for file names"
Button .tbar.exit -text "$char_cross" -foreground "#dd0000" -command { exit } \
  -helptext "Terminate the program" -helptype balloon
button .tbar.help -text "?" -width 1
.tbar.help configure -command { tk_messageBox -message "$APPNAME: basic usage" -detail $help  -type ok }
ComboBox .tbar.frame -textvariable frame -width 13 -modifycmd {SetFrameSize}
set frame ""
if {"$vlib"=="v4l2"} {
  spinbox .tbar.frate -width 5 -textvariable frate -command {SetFrameRate}
  bind .tbar.frate <Leave> {SetFrameRate}
  }\
else {
  ComboBox .tbar.frate -width 5 -textvariable frate -modifycmd {SetFrameRate}
  }
set frate ""
label .tbar.lab -text "fps | exposure:"
spinbox .tbar.exp -width 5 -textvariable exp
set exp ""
DynamicHelp::register .tbar.exp balloon "Exposure time, or type \"reset\" or \"auto\""

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
#uvc listen updateCameraList
