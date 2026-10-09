// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Trafira contributors
// A live guardian owns the process group until it has killed all its members.
#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <signal.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/prctl.h>
#include <sys/resource.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

static volatile sig_atomic_t interrupted;
static volatile sig_atomic_t group_ready;
static void stop_parent(int sig) { (void)sig; interrupted=1; }
static void stop_group(int sig) {
    (void)sig;
    if (group_ready) kill(-getpid(),SIGKILL);
    _exit(125);
}
static double now(void) {
    struct timespec value;
    if (clock_gettime(CLOCK_MONOTONIC,&value)<0) exit(125);
    return value.tv_sec+value.tv_nsec/1000000000.0;
}
static bool cancelled(const char *path,const char *id) {
    char buffer[16385],needle[100];
    int fd=open(path,O_RDONLY|O_NOFOLLOW|O_CLOEXEC);
    if(fd<0) return false;
    ssize_t size=read(fd,buffer,sizeof(buffer)-1);
    close(fd);
    if(size<=0) return false;
    buffer[size]=0;
    snprintf(needle,sizeof(needle),"\"%s\"",id);
    return strstr(buffer,needle)!=NULL;
}
static bool write_identity(void) {
    const char *path=getenv("TRAFIRA_WARP_PIDFILE");
    if(!path || !*path) return true;
    char raw[4096];
    FILE *stat=fopen("/proc/self/stat","r");
    if(!stat) return false;
    bool ok=fgets(raw,sizeof(raw),stat)!=NULL;
    fclose(stat);
    if(!ok) return false;
    char *end=strrchr(raw,')'),*save=NULL,*field=NULL;
    if(!end) return false;
    field=strtok_r(end+1," ",&save);
    for(int n=0; n<19 && field; n++) field=strtok_r(NULL," ",&save);
    if(!field || strspn(field,"0123456789")!=strlen(field)) return false;
    int fd=open(path,O_CREAT|O_EXCL|O_WRONLY|O_NOFOLLOW|O_CLOEXEC,0600);
    if(fd<0) return false;
    int count=dprintf(fd,"{\"pid\":\"%ld\",\"ticks\":\"%s\"}",(long)getpid(),field);
    ok=count>0 && fsync(fd)==0;
    close(fd);
    return ok;
}
int main(int argc,char **argv) {
    char *end;
    if(argc<5) return 2;
    long seconds=strtol(argv[1],&end,10);
    if(*end || seconds<0 || seconds>3600 || strlen(argv[3])>80 ||
       strspn(argv[3],"abcdefghijklmnopqrstuvwxyz0123456789-")!=strlen(argv[3])) return 2;
    struct sigaction sa={0};
    sa.sa_handler=stop_parent;
    sigemptyset(&sa.sa_mask);
    sigaction(SIGTERM,&sa,NULL);sigaction(SIGINT,&sa,NULL);sigaction(SIGHUP,&sa,NULL);
    pid_t parent=getppid();
    if(parent<=1 || prctl(PR_SET_PDEATHSIG,SIGTERM)<0 || getppid()!=parent) return 125;
    int channel[2];
    if(pipe2(channel,O_CLOEXEC|O_NONBLOCK)<0) return 125;
    pid_t supervisor=getpid();
    pid_t guardian=fork();
    if(guardian<0) return 125;
    if(!guardian) {
        close(channel[0]);
        sa.sa_handler=stop_group;
        sigaction(SIGTERM,&sa,NULL);sigaction(SIGINT,&sa,NULL);sigaction(SIGHUP,&sa,NULL);
        if(setsid()<0) _exit(125);
        group_ready=1;
        if(prctl(PR_SET_PDEATHSIG,SIGTERM)<0 || getppid()!=supervisor || interrupted) stop_group(0);
        pid_t worker=fork();
        if(worker<0) stop_group(0);
        if(!worker) {
            close(channel[1]);
            sa.sa_handler=SIG_DFL;
            sigaction(SIGTERM,&sa,NULL);sigaction(SIGINT,&sa,NULL);sigaction(SIGHUP,&sa,NULL);
            struct rlimit maximum={2097152,2097152};
            if(setrlimit(RLIMIT_FSIZE,&maximum)<0) _exit(125);
            if(!write_identity()) _exit(125);
            execvp(argv[4],argv+4);
            _exit(127);
        }
        int status;
        while(waitpid(worker,&status,0)<0) if(errno!=EINTR) stop_group(0);
        int result=WIFEXITED(status)?WEXITSTATUS(status):128+WTERMSIG(status);
        if(write(channel[1],&result,sizeof(result))!=(ssize_t)sizeof(result)) stop_group(0);
        // Never exit before the supervisor requests group cleanup: this PID
        // remains allocated even if the command spawned surviving descendants.
        for(;;) pause();
    }
    close(channel[1]);
    int result=125;
    double deadline=now()+seconds;
    for(;;) {
        ssize_t size=read(channel[0],&result,sizeof(result));
        if(size==(ssize_t)sizeof(result)) break;
        if(size==0) { result=125; break; }
        if(interrupted || cancelled(argv[2],argv[3])) { result=130; break; }
        if(seconds && now()>=deadline) { result=124; break; }
        struct timespec delay={.tv_sec=0,.tv_nsec=100000000};
        nanosleep(&delay,NULL);
    }
    // guardian cannot be reused: it is our unreaped child, alive or a zombie.
    kill(guardian,SIGTERM);
    int status;
    while(waitpid(guardian,&status,0)<0 && errno==EINTR) {}
    close(channel[0]);
    return result;
}
