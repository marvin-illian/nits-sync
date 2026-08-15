# Third-Party Notices

Nits Sync's Apple-silicon DDC/CI transport was informed by and adapts small
portions of the service-discovery and DDC packet-framing techniques in these
MIT-licensed projects:

- **m1ddc**, Copyright (c) 2021 waydabber  
  <https://github.com/waydabber/m1ddc>
- **AppleSiliconDDC**, Copyright (c) 2021 Istvan T.  
  <https://github.com/waydabber/AppleSiliconDDC>
- **MonitorControl**, Copyright © 2017  
  <https://github.com/MonitorControl/MonitorControl>

The software above is distributed under the following license:

> MIT License
>
> Permission is hereby granted, free of charge, to any person obtaining a copy
> of this software and associated documentation files (the "Software"), to deal
> in the Software without restriction, including without limitation the rights
> to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
> copies of the Software, and to permit persons to whom the Software is
> furnished to do so, subject to the following conditions:
>
> The above copyright notice and this permission notice shall be included in
> all copies or substantial portions of the Software.
>
> THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
> IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
> FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
> AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
> LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
> OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
> SOFTWARE.

The private `IOAVService*` function declarations name Apple IOKit symbols and
are original compatibility declarations; Apple does not provide public headers
for them. They are weak-linked so the application can report unsupported
systems without failing to launch.
