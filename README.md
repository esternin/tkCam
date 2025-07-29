# tkCam
<img width="422" alt="[screenshot]" src="https://github.com/user-attachments/assets/41c51a6e-61c8-4ada-b500-5530c7326f6f" />

tcl/tk USB camera (a.k.a. webcam) app, with live view and recording capabilities

tkCam comes in two versions, using <b>v4l2</b> or <b>uvc</b> protocols.  Both are available under [AndroWish](https://www.androwish.org/) (for Android) or [undroidwish or vanillawish](https://www.androwish.org/home/wiki?name=undroidwish) (for Linux, Windows, MacOS,...), a "batteries included" tcl/tk interpreter by Christian Werner. 

Under regular tcl/tk wish interpreter, <b>v4l2</b> is available as a separate library that can be installed from source,  see [https://androwish.org/home/file/undroid/v4l2/](https://androwish.org/home/file/undroid/v4l2/)

## `uvc`
tlcuvc library implementation of the [uvc](https://www.androwish.org/home/wiki?name=uvc) has only been tested under undroidwish/vanillawish. On Linux, a udev rule needs to be added allowing for detaching the kernel driver from the device. An example of `/etc/udev/rules.d/99-libuvc.rules` that accomplishes this is:
```
#libuvc: enable users in group "plugdev" to detach the uvcvideo kernel driver
ACTION=="add", SUBSYSTEM=="usb", ENV{ID_USB_INTERFACES}=="*:0e02??:*", GROUP="plugdev"
```
In addition, users must be in the `plugdev` group in order to be able to open the camera's USB connection. 

## `v4l2`
A straightforward installation: `./configure; make; sudo make install` is all it takes after downloading the source. The easiest way is to [download](https://androwish.org/download) the `.tar.gz` for the whole project, but extract only the `v4l2` subdirectory.
