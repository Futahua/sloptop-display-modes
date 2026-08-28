// DisplayCtl - attach/detach displays via the CCD API, allocating a distinct
// source per monitor.
//
// Why this exists: DisplaySwitch.exe /extend will not re-attach the panels that
// ipad mode detaches, and MultiMonitorTool cannot address a detached display at
// all (it exposes no Monitor ID). Windows Settings CAN reconnect them, because it
// enables a specific path rather than applying a topology preset.
//
// THE THING THAT MAKES THIS WORK: QueryDisplayConfig(QDC_ALL_PATHS) returns every
// legal source->target combination, in priority order. Naively activating the
// first candidate for each monitor gives every one of them source 0 - and in the
// Windows display model, several active targets sharing one source is a CLONE
// GROUP, not an extended desktop. That is why an earlier version of this tool
// produced "four active CCD paths, two screens in GDI": SetDisplayConfig was not
// failing, it was faithfully building the clone topology it had been handed.
//
// So this allocates. It reserves the sources already used by displays it is not
// rebuilding, then for each requested monitor picks an ALREADY ENUMERATED path
// whose source is still free. Source ids are never rewritten - inventing
// source->target pairings Windows did not enumerate yields ERROR_INVALID_PARAMETER
// (87), which is what an earlier attempt here did.
//
// Usage:
//   DisplayCtl.exe list                       - every path, active or not
//   DisplayCtl.exe enable  <match> [<match>…] - attach; pass ALL targets at once
//   DisplayCtl.exe disable <match> [<match>…] - detach
//   ... --save                                - also persist to the config database
//
// Pass every monitor you want on in a single enable call. Enabling them one at a
// time makes each new path claim the source the previous one just took.
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

    // Mode contents are never inspected here - Windows re-derives them - so the
    // union is just a correctly sized blob. Real fields rather than an empty
    // Explicit struct, which does not marshal reliably.
    [StructLayout(LayoutKind.Sequential)]
    public struct MODE_UNION { public ulong a, b, c, d, e, f; }

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

    public const uint QDC_ALL_PATHS          = 0x00000001;
    // Required once a virtual display is in the topology: Win10+ paths can use
    // the packed source/target mode-index fields, and a non-aware query returns a
    // view that does not round-trip cleanly back through SetDisplayConfig.
    public const uint QDC_VIRTUAL_MODE_AWARE = 0x00000010;

    public const uint SDC_USE_SUPPLIED_DISPLAY_CONFIG = 0x00000020;
    public const uint SDC_VALIDATE                    = 0x00000040;
    public const uint SDC_APPLY                       = 0x00000080;
    public const uint SDC_SAVE_TO_DATABASE            = 0x00000200;
    public const uint SDC_ALLOW_CHANGES               = 0x00000400;
    public const uint SDC_VIRTUAL_MODE_AWARE          = 0x00008000;

    public const uint PATH_ACTIVE      = 0x00000001;
    public const uint MODE_IDX_INVALID = 0xffffffff;
    public const uint GET_TARGET_NAME  = 2;

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

    // A source belongs to one adapter, so the adapter LUID is part of its identity.
    static string SourceKey(Native.PATH_INFO p)
    {
        return p.sourceInfo.adapterId.HighPart + ":" + p.sourceInfo.adapterId.LowPart
             + ":" + p.sourceInfo.id;
    }

    static bool Matches(string devicePath, string friendly, List<string> matches)
    {
        foreach (var m in matches)
        {
            if (devicePath.IndexOf(m, StringComparison.OrdinalIgnoreCase) >= 0
             || friendly.IndexOf(m, StringComparison.OrdinalIgnoreCase) >= 0) return true;
        }
        return false;
    }

    static int Main(string[] args)
    {
        if (args.Length < 1)
        {
            Console.Error.WriteLine("usage: DisplayCtl.exe list | enable <match>... | disable <match>... [--save]");
            return 1;
        }
        string cmd = args[0].ToLowerInvariant();
        var matches = new List<string>();
        bool save = false;
        for (int i = 1; i < args.Length; i++)
        {
            if (string.Equals(args[i], "--save", StringComparison.OrdinalIgnoreCase)) { save = true; continue; }
            matches.Add(args[i]);
        }

        uint queryFlags = Native.QDC_ALL_PATHS | Native.QDC_VIRTUAL_MODE_AWARE;

        uint numPaths, numModes;
        if (Native.GetDisplayConfigBufferSizes(queryFlags, out numPaths, out numModes) != 0)
        {
            Console.Error.WriteLine("GetDisplayConfigBufferSizes failed"); return 1;
        }
        var paths = new Native.PATH_INFO[numPaths];
        var modes = new Native.MODE_INFO[numModes];
        if (Native.QueryDisplayConfig(queryFlags, ref numPaths, paths, ref numModes, modes, IntPtr.Zero) != 0)
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
                string smi = paths[i].sourceInfo.modeInfoIdx == Native.MODE_IDX_INVALID ? "-" : paths[i].sourceInfo.modeInfoIdx.ToString();
                string tmi = paths[i].targetInfo.modeInfoIdx == Native.MODE_IDX_INVALID ? "-" : paths[i].targetInfo.modeInfoIdx.ToString();
                Console.WriteLine("{0,-6} avail={1,-5} adapter={2}:{3} src={4,-3} tgt={5,-9} srcMode={6,-3} tgtMode={7,-3} {8}",
                    active ? "ACTIVE" : "off",
                    paths[i].targetInfo.targetAvailable != 0,
                    paths[i].sourceInfo.adapterId.HighPart, paths[i].sourceInfo.adapterId.LowPart,
                    paths[i].sourceInfo.id, paths[i].targetInfo.id, smi, tmi, fr);
            }
            return 0;
        }

        if (cmd == "selftest")
        {
            // Validate the CURRENT configuration, unmodified. If this fails, the
            // problem is the flags or the array handling, not the allocation.
            var combos = new List<KeyValuePair<string,uint>>();
            combos.Add(new KeyValuePair<string,uint>("supplied+changes+vma", Native.SDC_USE_SUPPLIED_DISPLAY_CONFIG|Native.SDC_ALLOW_CHANGES|Native.SDC_VIRTUAL_MODE_AWARE));
            combos.Add(new KeyValuePair<string,uint>("supplied+changes",     Native.SDC_USE_SUPPLIED_DISPLAY_CONFIG|Native.SDC_ALLOW_CHANGES));
            combos.Add(new KeyValuePair<string,uint>("supplied+vma",         Native.SDC_USE_SUPPLIED_DISPLAY_CONFIG|Native.SDC_VIRTUAL_MODE_AWARE));
            combos.Add(new KeyValuePair<string,uint>("supplied only",        Native.SDC_USE_SUPPLIED_DISPLAY_CONFIG));
            var act = new List<Native.PATH_INFO>();
            for (int i = 0; i < numPaths; i++) if ((paths[i].flags & Native.PATH_ACTIVE) != 0) act.Add(paths[i]);
            var actArr = act.ToArray();
            Console.WriteLine("paths={0} active={1} modes={2}", numPaths, actArr.Length, numModes);
            foreach (var c in combos)
            {
                int a = Native.SetDisplayConfig(numPaths, paths, numModes, modes, Native.SDC_VALIDATE | c.Value);
                int b = Native.SetDisplayConfig((uint)actArr.Length, actArr, numModes, modes, Native.SDC_VALIDATE | c.Value);
                Console.WriteLine("  {0,-22} allPaths->{1,-4} activeOnly->{2}", c.Key, a, b);
            }
            return 0;
        }
        if (cmd != "enable" && cmd != "disable")
        {
            Console.Error.WriteLine("unknown command: " + cmd); return 1;
        }
        if (matches.Count == 0)
        {
            Console.Error.WriteLine("at least one <match> argument is required for " + cmd); return 1;
        }

        uint supplied = Native.SDC_USE_SUPPLIED_DISPLAY_CONFIG
                      | Native.SDC_ALLOW_CHANGES
                      | Native.SDC_VIRTUAL_MODE_AWARE;   // required: without it even
                                                         // the current config fails validation

        if (cmd == "disable")
        {
            int changes = 0;
            for (int i = 0; i < numPaths; i++)
            {
                string dp, fr;
                if (!TryGetName(paths[i], out dp, out fr)) continue;
                if (!Matches(dp, fr, matches)) continue;
                if ((paths[i].flags & Native.PATH_ACTIVE) == 0) continue;
                paths[i].flags &= ~Native.PATH_ACTIVE;
                changes++;
                Console.WriteLine("disabling src={0} tgt={1} {2}", paths[i].sourceInfo.id, paths[i].targetInfo.id, fr);
            }
            if (changes == 0) { Console.WriteLine("nothing to change"); return 0; }
            int drc = Native.SetDisplayConfig(numPaths, paths, numModes, modes, Native.SDC_VALIDATE | supplied);
            Console.WriteLine("validate -> " + drc);
            if (drc != 0) { Console.Error.WriteLine("rejected; nothing applied"); return 1; }
            uint df = Native.SDC_APPLY | supplied;
            if (save) df |= Native.SDC_SAVE_TO_DATABASE;
            drc = Native.SetDisplayConfig(numPaths, paths, numModes, modes, df);
            Console.WriteLine("apply -> " + drc);
            return drc == 0 ? 0 : 1;
        }

        // ENABLE.
        //
        // Picking the first free source per monitor produces a legal-looking
        // assignment that Windows still rejects - not every source can drive every
        // target on this hardware. Rather than guess, enumerate the candidate rows
        // per monitor and SEARCH: try each combination of distinct sources and ask
        // SDC_VALIDATE which one is actually legal. Nothing is applied until a
        // combination validates, so a wrong guess costs nothing.
        var reserved = new HashSet<string>();
        for (int i = 0; i < numPaths; i++)
        {
            if ((paths[i].flags & Native.PATH_ACTIVE) == 0) continue;
            string dp, fr;
            if (!TryGetName(paths[i], out dp, out fr)) continue;
            if (Matches(dp, fr, matches)) continue;   // being rebuilt
            reserved.Add(SourceKey(paths[i]));
        }

        // Candidate rows per monitor, keyed by device path, in enumeration order.
        var targetOrder = new List<string>();
        var candidates = new Dictionary<string, List<int>>();
        var friendlyOf = new Dictionary<string, string>();
        for (int i = 0; i < numPaths; i++)
        {
            string dp, fr;
            if (!TryGetName(paths[i], out dp, out fr)) continue;
            if (!Matches(dp, fr, matches)) continue;
            if (paths[i].targetInfo.targetAvailable == 0) continue;
            if (!candidates.ContainsKey(dp)) { candidates[dp] = new List<int>(); targetOrder.Add(dp); friendlyOf[dp] = fr; }
            if (reserved.Contains(SourceKey(paths[i]))) continue;   // source belongs to someone else
            candidates[dp].Add(i);
        }
        foreach (var dp in targetOrder)
            Console.WriteLine("{0}: {1} candidate path(s)", friendlyOf[dp], candidates[dp].Count);
        if (targetOrder.Count == 0) { Console.WriteLine("nothing to change"); return 0; }

        // Baseline: every path with the rebuilt targets switched off.
        var baseline = (Native.PATH_INFO[])paths.Clone();
        for (int i = 0; i < numPaths; i++)
        {
            string dp, fr;
            if (!TryGetName(baseline[i], out dp, out fr)) continue;
            if (Matches(dp, fr, matches)) baseline[i].flags &= ~Native.PATH_ACTIVE;
        }

        int[] pick = new int[targetOrder.Count];
        int attempts = 0;
        Native.PATH_INFO[] winner = null;

        Func<int, HashSet<string>, bool> search = null;
        search = delegate(int depth, HashSet<string> usedSources)
        {
            if (depth == targetOrder.Count)
            {
                var cand = (Native.PATH_INFO[])baseline.Clone();
                for (int k = 0; k < pick.Length; k++)
                {
                    int idx = pick[k];
                    cand[idx].flags |= Native.PATH_ACTIVE;
                    cand[idx].sourceInfo.modeInfoIdx = Native.MODE_IDX_INVALID;
                    cand[idx].targetInfo.modeInfoIdx = Native.MODE_IDX_INVALID;
                }
                attempts++;
                int vrc = Native.SetDisplayConfig(numPaths, cand, numModes, modes, Native.SDC_VALIDATE | supplied);
                if (vrc == 0) { winner = cand; return true; }
                return false;
            }
            foreach (int idx in candidates[targetOrder[depth]])
            {
                string sk = SourceKey(paths[idx]);
                if (usedSources.Contains(sk)) continue;
                usedSources.Add(sk);
                pick[depth] = idx;
                if (search(depth + 1, usedSources)) return true;
                usedSources.Remove(sk);
            }
            return false;
        };

        search(0, new HashSet<string>(reserved));

        if (winner == null)
        {
            Console.Error.WriteLine("no valid source assignment found after " + attempts + " combinations");
            return 1;
        }

        for (int k = 0; k < pick.Length; k++)
        {
            int idx = pick[k];
            string dp2, fr2;
            TryGetName(paths[idx], out dp2, out fr2);
            Console.WriteLine("selected src={0} tgt={1} {2}", paths[idx].sourceInfo.id, paths[idx].targetInfo.id, fr2);
        }
        Console.WriteLine("validated after " + attempts + " combination(s)");

        uint af = Native.SDC_APPLY | supplied;
        if (save) af |= Native.SDC_SAVE_TO_DATABASE;
        int rc = Native.SetDisplayConfig(numPaths, winner, numModes, modes, af);
        Console.WriteLine("apply -> " + rc);
        return rc == 0 ? 0 : 1;
    }
}