Fast Shutter Control using the XMOS XS1 platform, version 1.0

Copyright 2010,2011, Michael Sarahan
Distributed under the terms of the GNU public license, Version 3.  This license is detailed in the LICENSE.txt file.

This is a simple program for the XMOS XS1 platform, originally intended to control an electrostatic shutter
on a scanning transmission electron microscope.  It's primary purpose is to turn something (or multiple things)
on and off with very deterministic times, with minimum on/off switching times down to about 200 ns.

To use this code, you'll need an XMOS XS1 device.  The XS1 is the name of the architecture, and there are
several different devices you might find.  The code was developed on an XC-1A development board, which
has an XS1-G4 chip.

To flash this code to your XMOS device:
- Check out the source code from this repository.
- Open the XMOS development environment.
- Click File-> Import...
- In the General folder, select "Existing projects into workspace"
- Point the root directory to the folder where you have the source code.
- Click OK/Finish
- Click Project -> Properties
- Expand the C/XC build menu, then click settings in its submenu
- Under the mapper/linker settings, set the target to be the proper target for your XMOS device (for me, 
	it was an XC-1A, since that's what device I have.)
- Everything is all set up now, you can flash the fast beam shutter code over as you would any other XMOS
	program.

Have fun & good luck.