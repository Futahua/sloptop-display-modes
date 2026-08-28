// DisplayCtl - attach/detach one specific display path via the CCD API.
//
// Why this exists: DisplaySwitch.exe /extend applies a blanket "extend" topology
// and will not re-attach certain detached panels - on this machine SAC2453 and
// EDR2380 stay dark through it even though both are healthy in hardware. Windows
// Settings CAN reconnect them, because "Extend desktop to this display" enables
// one specific path rather than applying a topology preset. That is what this
// does: QueryDisplayConfig for every path including inactive ones, flip the
// ACTIVE flag on the one you name, and hand the whole set back to Windows.
//
// Usage:
//   DisplayCtl.exe list                  - every path, active or not
//   DisplayCtl.exe enable  <match>       - attach paths whose device path/name matches
//   DisplayCtl.exe disable <match>       - detach them
//
// <match> is a case-insensitive substring of the monitor device path (e.g.
// "SAC2453") or of the friendly name. Exit code 0 = applied, 1 = nothing matched
// or the call failed.
//
// Build:  csc /target:exe /out:DisplayCtl.exe DisplayCtl.cs

using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;

static class Native
{
    [StructLayout(LayoutKind.Sequential)]
    public struct LUID { public uint LowPart; public int HighPart; }

    [StructLayout(LayoutKind.Sequential)]
    public struct PATH_SOURCE_INFO
    {
        public LUID adapterId; public uint id; public uint modeInfoIdx;
        // Easy to miss: the native struct has a trailing statusFlags. Without it
        // PATH_INFO marshals as 68 bytes instead of 72 and QueryDisplayConfig
        // writes past the end of the array - which corrupts the heap.
        public uint statusFlags;
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct RATIONAL { public uint Numerator; public uint Denominator; }

    [StructLayout(LayoutKind.Sequential)]
    public struct PATH_TARGET_INFO
    {
        public LUID adapterId;
        public uint id;
        public uint modeInfoIdx;
        public uint outputTechnology;
        public uint rotation;
        public uint scaling;
        public RATIONAL refreshRate;
        public uint scanLineOrdering;
        public int targetAvailable;
        public uint statusFlags;
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct PATH_INFO
    {
        public PATH_SOURCE_INFO sourceInfo;
        public PATH_TARGET_INFO targetInfo;
        public uint flags;
    }

    // We never inspect mode contents - they are re-derived by Windows - so the
    // union is just a correctly sized blob. Declared as real fields rather than
    // an empty Explicit struct, which does not marshal reliably.
    [StructLayout(LayoutKind.Sequential)]
    public struct MODE_UNION
    {
        public ulong a, b, c, d, e, f;
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct MODE_INFO
    {
        public uint infoType;
        public uint id;
        public LUID adapterId;
        public MODE_UNION mode;
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct DEVICE_INFO_HEADER
    {
        public uint type; public uint size; public LUID adapterId; public uint id;
    }

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    public struct TARGET_DEVICE_NAME
    {
        public DEVICE_INFO_HEADER header;
        public uint flags;
        public uint outputTechnology;
        public ushort edidManufactureId;
        public ushort edidProductCodeId;
        public uint connectorInstance;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 64)] public string monitorFriendlyDeviceName;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)] public string monitorDevicePath;
    }

    public const uint QDC_ALL_PATHS = 0x00000001;

    public const uint SDC_USE_SUPPLIED_DISPLAY_CONFIG = 0x00000020;
    public const uint SDC_APPLY                       = 0x00000080;
    public const uint SDC_SAVE_TO_DATABASE            = 0x00000200;
    public const uint SDC_ALLOW_CHANGES               = 0x00000400;
    public const uint SDC_ALLOW_PATH_ORDER_CHANGES    = 0x00002000;
    public const uint SDC_TOPOLOGY_SUPPLIED           = 0x00000010;

    public const uint PATH_ACTIVE          = 0x00000001;
    public const uint MODE_IDX_INVALID     = 0xffffffff;
    public const uint GET_TARGET_NAME      = 2;

    [DllImport("user32.dll")]
    public static extern int GetDisplayConfigBufferSizes(uint flags, out uint numPaths, out uint numModes);

    [DllImport("user32.dll")]
    public static extern int QueryDisplayConfig(uint flags, ref uint numPaths, [Out] PATH_INFO[] paths,
        ref uint numModes, [Out] MODE_INFO[] modes, IntPtr currentTopologyId);

    [DllImport("user32.dll")]
    public static extern int SetDisplayConfig(uint numPaths, [In] PATH_INFO[] paths,
        uint numModes, [In] MODE_INFO[] modes, uint flags);

    [DllImport("user32.dll")]
    public static extern int DisplayConfigGetDeviceInfo(ref TARGET_DEVICE_NAME deviceName);
}

class Program
{
    static bool TryGetName(Native.PATH_INFO p, out string devicePath, out string friendly)
    {
        var tdn = new Native.TARGET_DEVICE_NAME();
        tdn.header.type = Native.GET_TARGET_NAME;
        tdn.header.size = (uint)Marshal.SizeOf(typeof(Native.TARGET_DEVICE_NAME));
        tdn.header.adapterId = p.targetInfo.adapterId;
        tdn.header.id = p.targetInfo.id;
        if (Native.DisplayConfigGetDeviceInfo(ref tdn) != 0)
        {
            devicePath = null; friendly = null; return false;
        }
        devicePath = tdn.monitorDevicePath ?? "";
        friendly = tdn.monitorFriendlyDeviceName ?? "";
        return true;
    }

    static int Main(string[] args)
    {
        if (args.Length < 1)
        {
            Console.Error.WriteLine("usage: DisplayCtl.exe list | enable <match> | disable <match>");
            return 1;
        }
        string cmd = args[0].ToLowerInvariant();
        // Several targets may be given. They MUST be applied in a single call:
        // activating paths one at a time makes each new path steal a source slot
        // from the previous one, so the panels knock each other back off.
        var matches = new List<string>();
        for (int ai = 1; ai < args.Length; ai++) matches.Add(args[ai]);

        uint numPaths, numModes;
        if (Native.GetDisplayConfigBufferSizes(Native.QDC_ALL_PATHS, out numPaths, out numModes) != 0)
        {
            Console.Error.WriteLine("GetDisplayConfigBufferSizes failed"); return 1;
        }
        var paths = new Native.PATH_INFO[numPaths];
        var modes = new Native.MODE_INFO[numModes];
        if (Native.QueryDisplayConfig(Native.QDC_ALL_PATHS, ref numPaths, paths, ref numModes, modes, IntPtr.Zero) != 0)
        {
            Console.Error.WriteLine("QueryDisplayConfig failed"); return 1;
        }

        if (cmd == "list")
        {
            for (int i = 0; i < numPaths; i++)
            {
                string dp, fr;
                if (!TryGetName(paths[i], out dp, out fr)) continue;
                bool active = (paths[i].flags & Native.PATH_ACTIVE) != 0;
                Console.WriteLine("{0,-8} avail={1,-5} {2,-28} {3}",
                    active ? "ACTIVE" : "off", paths[i].targetInfo.targetAvailable != 0, fr, dp);
            }
            return 0;
        }

        if (matches.Count == 0)
        {
            Console.Error.WriteLine("at least one <match> argument is required for " + cmd); return 1;
        }
        bool wantActive = (cmd == "enable");
        if (cmd != "enable" && cmd != "disable")
        {
            Console.Error.WriteLine("unknown command: " + cmd); return 1;
        }

        // A monitor is reachable through several candidate paths (different source
        // pairings) but only ONE may be active at a time. So when enabling, take
        // the first usable path per monitor and leave its siblings alone -
        // activating them all produces a conflicting topology that gets rejected.
        var alreadyActive = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        for (int i = 0; i < numPaths; i++)
        {
            string dp0, fr0;
            if (!TryGetName(paths[i], out dp0, out fr0)) continue;
            if ((paths[i].flags & Native.PATH_ACTIVE) != 0) alreadyActive.Add(dp0);
        }

        var handled = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        var enabledIdx = new List<int>();
        int hits = 0;
        for (int i = 0; i < numPaths; i++)
        {
            string dp, fr;
            if (!TryGetName(paths[i], out dp, out fr)) continue;
            bool isMatch = false;
            foreach (var mm in matches)
            {
                if (dp.IndexOf(mm, StringComparison.OrdinalIgnoreCase) >= 0
                 || fr.IndexOf(mm, StringComparison.OrdinalIgnoreCase) >= 0) { isMatch = true; break; }
            }
            if (!isMatch) continue;

            if (wantActive)
            {
                if (paths[i].targetInfo.targetAvailable == 0)
                {
                    Console.WriteLine("skip (not physically available): " + fr);
                    continue;
                }
                if (handled.Contains(dp)) continue;   // sibling path for the same monitor
                // NOTE: a path can carry the ACTIVE flag while the display does not
                // actually exist in GDI - the CCD table and the live desktop drift
                // apart. So never treat "flag already set" as "nothing to do";
                // re-apply regardless, which is what forces Windows to materialise it.
                if (!alreadyActive.Contains(dp)) paths[i].flags |= Native.PATH_ACTIVE;
                enabledIdx.Add(i);
                handled.Add(dp);
            }
            else
            {
                if ((paths[i].flags & Native.PATH_ACTIVE) == 0) continue;
                paths[i].flags &= ~Native.PATH_ACTIVE;
            }
            hits++;
            Console.WriteLine((wantActive ? "enabling: " : "disabling: ") + fr + "  " + dp);
        }

        if (hits == 0)
        {
            // Nothing changed. If the targets are already in the requested state
            // that is success, not failure.
            Console.WriteLine("nothing to change");
            return 0;
        }

        // Windows is fussy about exactly what combination it will accept here, and
        // which one works depends on the driver and the current topology. Rather
        // than guess, try the sensible variants in order and report which landed.
        // Clear the mode indices of just the paths we are turning on, so Windows
        // allocates them fresh source slots. Leaving their queried indices in place
        // is what makes two targets collide on one source - the call then succeeds
        // while the display never appears.
        if (wantActive)
        {
            foreach (int ei in enabledIdx)
            {
                paths[ei].sourceInfo.modeInfoIdx = Native.MODE_IDX_INVALID;
                paths[ei].targetInfo.modeInfoIdx = Native.MODE_IDX_INVALID;
            }
        }

        uint baseFlags = Native.SDC_APPLY | Native.SDC_USE_SUPPLIED_DISPLAY_CONFIG | Native.SDC_ALLOW_CHANGES;

        var attempts = new List<KeyValuePair<string, Func<int>>>();

        // 1. Topology-only apply: paths, no modes. This is the legal way to pass a
        //    null mode array - SDC_USE_SUPPLIED_DISPLAY_CONFIG requires modes.
        attempts.Add(new KeyValuePair<string, Func<int>>("topology supplied", () =>
        {
            var keep = new List<Native.PATH_INFO>();
            for (int i = 0; i < numPaths; i++)
                if ((paths[i].flags & Native.PATH_ACTIVE) != 0) keep.Add(paths[i]);
            var arr = keep.ToArray();
            return Native.SetDisplayConfig((uint)arr.Length, arr, 0, null,
                   Native.SDC_APPLY | Native.SDC_TOPOLOGY_SUPPLIED | Native.SDC_ALLOW_PATH_ORDER_CHANGES);
        }));

        // 2. Fall back to supplied paths with the modes exactly as queried.
        attempts.Add(new KeyValuePair<string, Func<int>>("supplied paths + queried modes",
            () => Native.SetDisplayConfig(numPaths, paths, numModes, modes, baseFlags | Native.SDC_SAVE_TO_DATABASE)));

        // 2. Same, but let Windows reorder paths.
        attempts.Add(new KeyValuePair<string, Func<int>>("+ allow path order changes",
            () => Native.SetDisplayConfig(numPaths, paths, numModes, modes,
                  baseFlags | Native.SDC_SAVE_TO_DATABASE | Native.SDC_ALLOW_PATH_ORDER_CHANGES)));

        // 3. Without saving to the persistence database.
        attempts.Add(new KeyValuePair<string, Func<int>>("without save-to-database",
            () => Native.SetDisplayConfig(numPaths, paths, numModes, modes, baseFlags)));

        foreach (var a in attempts)
        {
            int rc = a.Value();
            if (rc == 0) { Console.WriteLine("applied (" + a.Key + ")"); return 0; }
            Console.WriteLine("  tried " + a.Key + " -> code " + rc);
        }
        Console.Error.WriteLine("SetDisplayConfig rejected every variant");
        return 1;
    }
}
