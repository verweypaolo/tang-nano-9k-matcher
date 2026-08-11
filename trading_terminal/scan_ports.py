"""
scan_ports.py — one-off diagnostic script.

Lists every serial port macOS currently sees, highlighting anything with
"usbserial" in its device path, and prints every field pyserial exposes for
it (description, manufacturer, vid/pid, serial_number, etc.).

Run this with the Tang Nano 9K plugged in to see exactly what identifying
information is available, so find_tang_nano_port() in serial_link.py can be
built to match on something stable (description/manufacturer/vid:pid)
rather than the device path's numeric suffix, which changes across
reconnects.
"""

import serial.tools.list_ports

ports = list(serial.tools.list_ports.comports())

if not ports:
    print("No serial ports found at all.")
else:
    print(f"Found {len(ports)} serial port(s):\n")

for port in ports:
    is_usbserial = "usbserial" in port.device.lower()
    marker = "  <-- usbserial" if is_usbserial else ""
    print(f"device:        {port.device}{marker}")
    print(f"name:          {port.name}")
    print(f"description:   {port.description}")
    print(f"manufacturer:  {port.manufacturer}")
    print(f"product:       {port.product}")
    print(f"serial_number: {port.serial_number}")
    print(f"vid:pid:       {port.vid}:{port.pid}")
    print(f"hwid:          {port.hwid}")
    print("-" * 60)