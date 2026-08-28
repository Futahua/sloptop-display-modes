using System;
using System.Runtime.InteropServices;

[ComImport]
[Guid("B92B56A9-8B55-4E14-9A89-0199BBB6F93B")]
[InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
interface IDesktopWallpaper
{
    void SetWallpaper([MarshalAs(UnmanagedType.LPWStr)] string monitorID, [MarshalAs(UnmanagedType.LPWStr)] string wallpaper);
    [return: MarshalAs(UnmanagedType.LPWStr)] string GetWallpaper([MarshalAs(UnmanagedType.LPWStr)] string monitorID);
    [return: MarshalAs(UnmanagedType.LPWStr)] string GetMonitorDevicePathAt(uint monitorIndex);
    [return: MarshalAs(UnmanagedType.U4)] uint GetMonitorDevicePathCount();
    void GetMonitorRECT([MarshalAs(UnmanagedType.LPWStr)] string monitorID, out RECT rc);
    void SetBackgroundColor(uint color);
    uint GetBackgroundColor();
    void SetPosition(int position);
    int GetPosition();
    void SetSlideshow(IntPtr items);
    void GetSlideshow(out IntPtr items);
    void SetSlideshowOptions(uint options, uint tick);
    void GetSlideshowOptions(out uint options, out uint tick);
    void AdvanceSlideshow([MarshalAs(UnmanagedType.LPWStr)] string monitorID, int direction);
    int GetStatus();
    void Enable(bool enable);
}

[StructLayout(LayoutKind.Sequential)]
struct RECT { public int Left, Top, Right, Bottom; }

[ComImport]
[Guid("C2CF3110-460E-4FC1-B9D0-8A1C0C9CC4BD")]
[ClassInterface(ClassInterfaceType.None)]
class DesktopWallpaperClass { }

class Program
{
    [DllImport("user32.dll", CharSet = CharSet.Auto)]
    static extern int SystemParametersInfo(int uAction, int uParam, string lpvParam, int fuWinIni);

    const int SPI_SETDESKWALLPAPER = 20;
    const int SPIF_UPDATEINIFILE = 0x01;
    const int SPIF_SENDCHANGE = 0x02;

    static void Main(string[] args)
    {
        var wp = (IDesktopWallpaper)new DesktopWallpaperClass();
        uint count = wp.GetMonitorDevicePathCount();

        if (args.Length == 1 && args[0] == "list")
        {
            for (uint i = 0; i < count; i++)
                Console.WriteLine("[" + i + "] " + wp.GetMonitorDevicePathAt(i));
            return;
        }

        string primaryWallpaper = null;
        for (int j = 0; j < args.Length - 1; j++)
        {
            if (args[j] == "--primary")
            {
                primaryWallpaper = args[j + 1];
                break;
            }
        }

        for (uint i = 0; i < count; i++)
        {
            string path = wp.GetMonitorDevicePathAt(i);
            for (int j = 0; j + 1 < args.Length; j += 2)
            {
                if (args[j] == "--primary") { j++; continue; }
                // Match anywhere in the path — supports model names like EDR2380
                // and also UID strings like UID256 to distinguish duplicate Default_Monitor entries
                if (path.IndexOf(args[j], StringComparison.OrdinalIgnoreCase) >= 0)
                {
                    wp.SetWallpaper(path, args[j + 1]);
                    Console.WriteLine("Set " + args[j] + " -> " + args[j + 1]);
                }
            }
        }

        if (primaryWallpaper != null)
        {
            SystemParametersInfo(SPI_SETDESKWALLPAPER, 0, primaryWallpaper, SPIF_UPDATEINIFILE | SPIF_SENDCHANGE);
            Console.WriteLine("Global wallpaper set to: " + primaryWallpaper);
        }
    }
}
