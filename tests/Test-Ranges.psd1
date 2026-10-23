# Test-Ranges.psd1
#
# Known-valid value ranges for every processor power setting that
# modules\PowerTune.psm1 can write.  Consumed by tests\Invoke-Tests.ps1
# (range test + profile value validation).
#
# Field semantics
#   Min     - lowest value the setting accepts (inclusive)
#   Max     - highest value the setting accepts (inclusive)
#   Allowed - optional explicit enumeration; when present the value must be
#             a member of this list in addition to the Min/Max bounds
#   Note    - why the bound is what it is / where it came from
#
# Where the OS publishes an authoritative range, this table matches it.
# Those settings are cross-checked at test time against
#   HKLM\SYSTEM\CurrentControlSet\Control\Power\PowerSettings\
#      54533251-82be-4824-96c1-47b60b740d00\<setting guid>
#   -> ValueMin / ValueMax
# Settings that only expose an enumeration (boost mode, EPP policy, ...) have
# no ValueMin/ValueMax in the registry, so their bounds are the documented
# Windows semantics hardcoded here.

@{
    SchemaVersion = 1
    SubGroup      = '54533251-82be-4824-96c1-47b60b740d00'   # SUB_PROCESSOR

    Settings = @{

        # ── performance boost ──────────────────────────────────────────
        PERFBOOSTMODE = @{
            Min = 0; Max = 6
            Allowed = @(0, 1, 2, 3, 4, 5, 6)
            Note = '0 disabled, 1 enabled, 2 aggressive, 3 efficient enabled, 4 efficient aggressive, 5/6 ...at guaranteed'
        }
        PERFBOOSTPOL = @{
            Min = 0; Max = 100
            Note = 'percentage; registry publishes ValueMin=0 ValueMax=100'
        }

        # ── energy performance preference ──────────────────────────────
        PERFEPP  = @{ Min = 0; Max = 100; Note = '0 = max performance, 100 = max efficiency' }
        PERFEPP1 = @{ Min = 0; Max = 100; Note = 'efficiency class 1 mirror of PERFEPP' }

        # ── core parking ───────────────────────────────────────────────
        CPMINCORES          = @{ Min = 0; Max = 100; Note = 'percent; 100 = parking disabled' }
        CPMAXCORES          = @{ Min = 0; Max = 100; Note = 'percent' }
        CPCONCURRENCY       = @{ Min = 0; Max = 100; Note = 'percent threshold' }
        CPHEADROOM          = @{ Min = 0; Max = 100; Note = 'percent headroom threshold' }
        CPLATENCYHINTUNPARK = @{ Min = 0; Max = 100; Note = 'percent of cores to unpark on latency hint' }

        # ── heterogeneous scheduling ───────────────────────────────────
        PERFHETERO = @{
            Min = 0; Max = 7
            Allowed = @(0, 1, 2, 3, 4, 5, 6, 7)
            Note = '0 automatic .. 4 prefer P-cores; enumeration only, no registry ValueMin/Max'
        }
        PERFAUTONOMOUS = @{ Min = 0; Max = 1; Allowed = @(0, 1); Note = '0/1 boolean' }

        # ── frequency scaling ──────────────────────────────────────────
        PROCTHROTTLEMIN = @{ Min = 0; Max = 100; Note = 'percent of nominal frequency' }
        PROCTHROTTLEMAX = @{ Min = 0; Max = 100; Note = 'percent of nominal frequency' }
        THROTTLEMIN_EC1 = @{ Min = 0; Max = 100; Note = 'efficiency class 1 mirror' }
        THROTTLEMAX_EC1 = @{ Min = 0; Max = 100; Note = 'efficiency class 1 mirror' }
        PERFINCPOL = @{
            Min = 0; Max = 5
            Allowed = @(0, 1, 2, 3, 4, 5)
            Note = '0 disabled/conservative .. 2 always/aggressive; enumeration only'
        }
        PERFDECPOL = @{
            Min = 0; Max = 3
            Allowed = @(0, 1, 2, 3)
            Note = '0 conservative, 1 aggressive, 2/3 ...; enumeration only'
        }
        PERFINCTHRESHOLD = @{ Min = 0; Max = 100; Note = 'percent' }
        PERFDECTHRESHOLD = @{ Min = 0; Max = 100; Note = 'percent' }
        PERFLATENCYSENSITIVITY = @{ Min = 0; Max = 100; Note = 'percent' }
        MAXFREQ = @{
            Min = 0; Max = 4294967295
            Note = 'MHz; 0 = unlimited. registry publishes ValueMax=4294967295'
        }

        # ── idle / thermal ─────────────────────────────────────────────
        IDLEDISABLE   = @{ Min = 0; Max = 1; Allowed = @(0, 1); Note = '1 = disable idle states (costs power)' }
        SYSCOOLING    = @{ Min = 0; Max = 1; Allowed = @(0, 1); Note = '0 passive, 1 active' }
        ALLOWTHROTTLE = @{ Min = 0; Max = 2; Allowed = @(0, 1, 2); Note = 'throttle-state permission' }
        DUTYCYCLING   = @{ Min = 0; Max = 1; Allowed = @(0, 1); Note = '0 disabled, 1 enabled' }
        PERFRESOURCEPRIORITY = @{ Min = 0; Max = 100; Note = 'percent' }

        # ── read-only / unavailable (recorded, never written) ──────────
        PERFINCTIME = @{ Min = 1; Max = 100; Note = 'read-only on this platform; registry ValueMin=1 ValueMax=100' }
        PERFDECTIME = @{ Min = 1; Max = 100; Note = 'read-only on this platform; registry ValueMin=1 ValueMax=100' }
        PERFTIME    = @{ Min = 1; Max = 5000; Note = 'read-only on this platform; registry ValueMin=1 ValueMax=5000' }
        HETEROSCHED = @{
            Min = 0; Max = 5
            Allowed = @(0, 1, 2, 3, 4, 5)
            Note = 'heterogeneous thread scheduling policy; enumeration only'
        }
    }
}
