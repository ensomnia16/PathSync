#include <stdint.h>
#include <unistd.h>
#include <errno.h>
#include <string.h>
#include <CommonCrypto/CommonDigest.h>
/* One pass computes Graph's QuickXorHash and the existing SHA-256 anchor. */
int pathsync_hash_fd(int fd, unsigned char quick[20], unsigned char sha[32]) {
 unsigned char buf[262144], lanes[160]={0}; uint64_t length=0; unsigned pos=0;
 CC_SHA256_CTX context; CC_SHA256_Init(&context);
 for (;;) {
  ssize_t count=read(fd,buf,sizeof(buf));
  if(count<0) { if(errno==EINTR) continue; return -1; }
  if(!count) break;
  CC_SHA256_Update(&context,buf,(CC_LONG)count); length+=(uint64_t)count;
  for(ssize_t i=0;i<count;i++) { lanes[pos]^=buf[i]; if(++pos==160)pos=0; }
 }
 memset(quick,0,20);
 for(unsigned i=0;i<160;i++) {
  unsigned shift=(i*11)%160, byte=shift/8, bit=shift%8;
  quick[byte]^=(unsigned char)(lanes[i]<<bit);
  if(bit)quick[(byte+1)%20]^=(unsigned char)(lanes[i]>>(8-bit));
 }
 for(unsigned i=0;i<8;i++)quick[12+i]^=(unsigned char)(length>>(8*i));
 CC_SHA256_Final(sha,&context);return 0;
}
