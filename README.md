# tkCam

tcl/tk USB camera (a.k.a. webcam) app, with live view and recording capabilities

Needs to run under [AndroWish](https://www.androwish.org/) (for Android) or [undroidwish or vanillawish](https://www.androwish.org/home/wiki?name=undroidwish) (for Linux, Windows, MacOS,...), a "batteries included" tcl/tk interpreter by Christian Werner. 

In particular, uses tlcuvc library implementation of the [uvc](https://www.androwish.org/home/wiki?name=uvc) protocol to stream video from attached cameras.

On Linux, a udev rule needs to be added allowing for detaching the kernel driver from the device. An example of `/etc/udev/rules.d/99-libuvc.rules` that accomplishes this is :
```
#libuvc: enable users in group "plugdev" to detach the uvcvideo kernel driver
ACTION=="add", SUBSYSTEM=="usb", ENV{ID_USB_INTERFACES}=="*:0e02??:*", GROUP="plugdev"
```
In addition, users must be in the `plugdev` group in order to be able to open the camera's USB connection. 
