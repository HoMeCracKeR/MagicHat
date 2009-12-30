#import "MachOFileMO.h"
//#include "stuff/ofile.h"
//#include "stuff/allocate.h"
//#include "otool/ofile_print.h"
#import "MachOHeaderMO.h"
//#import "ASSIGN.h"

char *progname = "my_progname";

@interface MachOFileMO ()
- (void)processOFile:(struct ofile*)ofile archName:(char*)archName;
@end

void ofile_processor(struct ofile *ofile, char *arch_name, void *cookie) {
    [(MachOFileMO*)cookie processOFile:ofile archName:arch_name];
}

@implementation MachOFileMO
@synthesize fileData;

- (BOOL)parseFileURL:(NSURL*)url_ error:(NSError**)error_ {
    ofile_process(
        (char*)[[url_ path] fileSystemRepresentation], //  name
        NULL,               //  arch_flags
        0,                  //  narch_flags
        TRUE,               //  all_archs
        TRUE,               //  process_non_objects
        TRUE,               //  dylib_flat
        TRUE,               //  use_member_syntax
        ofile_processor,    //  processor
        self);              //  cookie
    
    return YES;
}

- (void)processOFile:(struct ofile*)ofile archName:(char*)arch_name {
    if(ofile->mh == NULL && ofile->mh64 == NULL)
	    return;
    
    if (!self.fileData) {
        // We currently leak struct ofile and its associated mmap of the mach-o file since
        // ofile's main client is otool, which doesn't bother cleaning up after itself and leaks.
        // Eventually we'll replace ofile with a ground-up ruby implementation that won't have this problem.
        self.fileData = [[NSData alloc] initWithBytesNoCopy:ofile->file_addr
                                                     length:ofile->file_size
                                               freeWhenDone:NO];
    }
    
    MachOHeaderMO *header = [MachOHeaderMO insertInManagedObjectContext:[self managedObjectContext]];
    [self addHeadersObject:header];
    header.archName = arch_name ? [NSString stringWithUTF8String:arch_name] : @"main arch";
    
    [header processOFile:ofile];
}

@end
