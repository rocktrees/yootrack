// SDK-layout shim only: algorithms and ownership remain in Rust.
#include <libproc.h>
#include <sys/resource.h>
#include <mach/mach_time.h>
#include <string.h>
#include <unistd.h>
#include <sys/sysctl.h>
struct PWInfo { uint64_t start; uint32_t parent, uid; char name[16]; };
struct PWUsage { uint64_t cpu, energy, memory; };
int pw_bsd(int pid, struct PWInfo *out) {
    struct proc_bsdinfo info = {0};
    if (proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, sizeof(info)) != sizeof(info)) return 0;
    out->start = info.pbi_start_tvsec * 1000000ULL + info.pbi_start_tvusec;
    out->parent = info.pbi_ppid; out->uid = info.pbi_uid;
    memcpy(out->name, info.pbi_comm, 16); return 1;
}
int pw_usage(int pid, struct PWUsage *out) {
    struct rusage_info_v6 info = {0};
    if (proc_pid_rusage(pid, RUSAGE_INFO_V6, (rusage_info_t *)&info) != 0) return 0;
    out->cpu = info.ri_user_time + info.ri_system_time;
    out->energy = info.ri_energy_nj; out->memory = info.ri_phys_footprint; return 1;
}
double pw_timebase(void) { mach_timebase_info_data_t info; mach_timebase_info(&info); return (double)info.numer / info.denom; }
double pw_cpu_seconds(void) {
    struct rusage info; getrusage(RUSAGE_SELF, &info);
    return info.ru_utime.tv_sec + info.ru_stime.tv_sec + (info.ru_utime.tv_usec + info.ru_stime.tv_usec) / 1000000.0;
}
int pw_energy_supported(void) {
    int supported=0; size_t size=sizeof(supported);
    if (sysctlbyname("kern.pervasive_energy", &supported, &size, NULL, 0)==0) return supported!=0;
    struct PWUsage self; return pw_usage(getpid(), &self) && self.energy>0;
}
