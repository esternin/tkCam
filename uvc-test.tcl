package require tcluvc
set DEBUG 1

foreach vd [uvc info] { uvc close $vd }

# On Linux, a udev rule needs to be added allowing for detaching the
# kernel driver from the device. Users must be in the `plugdev` group
# in order to be able to open the camera's USB device.
# An example `99-libuvc.rules` file is
#   #libuvc: enable users in group "plugdev" to detach the uvcvideo kernel driver
#   ACTION=="add", SUBSYSTEM=="usb", ENV{ID_USB_INTERFACES}=="*:0e02??:*", GROUP="plugdev"

proc findCameras {} {
  global DeviceMap
  set DeviceMap [dict create]
  set uvc_list [uvc devices]
  set l 0
  while {$l < [llength $uvc_list]} {
    set uvc_id   [lindex $uvc_list $l] ; incr l 2
    set usb_code [lindex [split $uvc_id :] 2]
    set uvc_name [lindex $uvc_list $l] ; incr l
    if {![catch {set vd [uvc open $uvc_id {}]}]} {
      uvc close $vd; 
      dict append DeviceMap "$uvc_name-$usb_code" $uvc_id
      } \
    else {
      puts "error accessing USB device $uvc_id; check udev rules/is user in plugdev?"
      }
    }
  return [dict keys $DeviceMap]
}

set DeviceMap ""
set DeviceList [findCameras]

if ($DEBUG) {foreach d $DeviceList {puts "$d --> [dict get $DeviceMap $d]"}}

## the first one
set vd [uvc open [dict get $DeviceMap [lindex $DeviceList 0]] {}]

set FormatsMap [uvc listformats $vd]

set fMap [dict create]
foreach i [dict keys [uvc listformats $vd]] {
  set f [dict get $FormatsMap $i]
  set frame [dict get $f frame-size]
  set frate [dict get $f frame-rate]
  set frates [dict get $f frame-rate-values]
  dict append fMap $frame@$frate $i
  }

if ($DEBUG) {puts "[dict keys $fMap]"}

set ind [dict get $fMap 1280x720@30]
puts "desired mode = $ind 30"
puts "  [dict get [dict get $FormatsMap $ind] frame-size]"
uvc format $vd $ind 30
puts "actual mode = [uvc format $vd]"


uvc close $vd

