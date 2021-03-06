/*
    Exe64Processor.m

    This file relies upon, and steals code from, the cctools source code
    available from: http://www.opensource.apple.com/darwinsource/

    This file is in the public domain.
*/

#import <Cocoa/Cocoa.h>

#import "Exe64Processor.h"
#import "Arch64Specifics.h"
#import "List64Utils.h"
#import "Objc64Accessors.h"
#import "Object64Loader.h"
#import "SysUtils.h"
#import "UserDefaultKeys.h"

@implementation Exe64Processor

// Exe64Processor is a base class that handles processor-independent issues.
// PPC64Processor and X8664Processor are subclasses that add functionality
// specific to those CPUs. The AppController class creates a new instance of
// one of those subclasses for each processing, and deletes the instance as
// soon as possible. Member variables may or may not be re-initialized before
// destruction. Do not reuse a single instance of those subclasses for
// multiple processings.

//  initWithURL:controller:options:
// ----------------------------------------------------------------------------

- (id)initWithURL: (NSURL*)inURL
       controller: (id)inController
          options: (ProcOptions*)inOptions
{
    if (!inURL || !inController || !inOptions)
        return nil;

    if ((self = [super initWithURL: inURL controller: inController
        options: inOptions]) == nil)
        return nil;

    return self;
}

//  dealloc
// ----------------------------------------------------------------------------

- (void)dealloc
{
    if (iFuncSyms)
    {
        free(iFuncSyms);
        iFuncSyms   = NULL;
    }

    if (iClassMethodInfos)
    {
        free(iClassMethodInfos);
        iClassMethodInfos   = NULL;
    }

    if (iLineArray)
    {
        free(iLineArray);
        iLineArray = NULL;
    }

    [self deleteFuncInfos];
    [self deleteLinesFromList: iPlainLineListHead];
    [self deleteLinesFromList: iVerboseLineListHead];

    [super dealloc];
}

//  deleteFuncInfos
// ----------------------------------------------------------------------------

- (void)deleteFuncInfos
{
    if (!iFuncInfos)
        return;

    uint32_t          i;
    uint32_t          j;
    Function64Info* funcInfo;
    Block64Info*    blockInfo;

    for (i = 0; i < iNumFuncInfos; i++)
    {
        funcInfo    = &iFuncInfos[i];

        if (funcInfo->blocks)
        {
            for (j = 0; j < funcInfo->numBlocks; j++)
            {
                blockInfo   = &funcInfo->blocks[j];

                if (blockInfo->state.regInfos)
                {
                    free(blockInfo->state.regInfos);
                    blockInfo->state.regInfos   = NULL;
                }

                if (blockInfo->state.localSelves)
                {
                    free(blockInfo->state.localSelves);
                    blockInfo->state.localSelves    = NULL;
                }
            }

            free(funcInfo->blocks);
            funcInfo->blocks    = NULL;
        }
    }

    free(iFuncInfos);
    iFuncInfos  = NULL;
}

#pragma mark -
//  processExe:
// ----------------------------------------------------------------------------
//  The master processing method, designed to be executed in a separate thread.

- (BOOL)processExe: (NSString*)inOutputFilePath
{
    if (!iFileArchMagic)
    {
        fprintf(stderr, "otx: tried to process non-machO file\n");
        return NO;
    }

    iOutputFilePath = inOutputFilePath;
    iMachHeaderPtr  = NULL;

    if (![self loadMachHeader])
    {
        fprintf(stderr, "otx: failed to load mach header\n");
        return NO;
    }

    [self loadLCommands];

    NSMutableDictionary*    progDict    =
        [[NSMutableDictionary alloc] initWithObjectsAndKeys:
        [NSNumber numberWithBool: YES], PRNewLineKey,
        @"Calling otool", PRDescriptionKey,
        nil];

#ifdef OTX_CLI
    [iController reportProgress: progDict];
#else
    [iController performSelectorOnMainThread: @selector(reportProgress:)
        withObject: progDict waitUntilDone: NO];
#endif

    [progDict release];

    [self populateLineLists];

    if (gCancel == YES)
        return NO;

    progDict    = [[NSMutableDictionary alloc] initWithObjectsAndKeys:
        [NSNumber numberWithBool: YES], PRNewLineKey,
        @"Gathering info", PRDescriptionKey,
        nil];

#ifdef OTX_CLI
    [iController reportProgress: progDict];
#else
    [iController performSelectorOnMainThread: @selector(reportProgress:)
        withObject: progDict waitUntilDone: NO];
#endif

    [progDict release];

    // Gather info about lines while they're virgin.
    [self gatherLineInfos];

    if (gCancel == YES)
        return NO;

    // Find functions and allocate funcInfo's.
    [self findFunctions];

    if (gCancel == YES)
        return NO;

    // Gather info about logical blocks. The second pass applies info
    // for backward branches.
    [self gatherFuncInfos];

    if (gCancel == YES)
        return NO;

    [self gatherFuncInfos];

    if (gCancel == YES)
        return NO;

    uint32_t  progCounter = 0;
    double  progValue   = 0.0;

    progDict    = [[NSMutableDictionary alloc] initWithObjectsAndKeys:
        [NSNumber numberWithBool: NO], PRIndeterminateKey,
        [NSNumber numberWithDouble: progValue], PRValueKey,
        [NSNumber numberWithBool: YES], PRNewLineKey,
        @"Generating file", PRDescriptionKey,
        nil];

#ifdef OTX_CLI
    [iController reportProgress: progDict];
#else
    [iController performSelectorOnMainThread: @selector(reportProgress:)
        withObject: progDict waitUntilDone: NO];
#endif

    [progDict release];

    Line64* theLine = iPlainLineListHead;

    // Loop thru lines.
    while (theLine)
    {
        if (!(progCounter % PROGRESS_FREQ))
        {
            if (gCancel == YES)
                return NO;

            progValue   = (double)progCounter / iNumLines * 100;
            progDict    = [[NSMutableDictionary alloc] initWithObjectsAndKeys:
                [NSNumber numberWithDouble: progValue], PRValueKey,
                nil];

#ifdef OTX_CLI
            [iController reportProgress: progDict];
#else
            [iController performSelectorOnMainThread: @selector(reportProgress:)
                withObject: progDict waitUntilDone: NO];
#endif

            [progDict release];
        }

        if (theLine->info.isCode)
        {
            ProcessCodeLine(&theLine);

            if (iOpts.entabOutput)
                EntabLine(theLine);
        }
        else
            ProcessLine(theLine);

        theLine = theLine->next;
        progCounter++;
    }

    if (gCancel == YES)
        return NO;

    progDict    = [[NSMutableDictionary alloc] initWithObjectsAndKeys:
        [NSNumber numberWithBool: YES], PRIndeterminateKey,
        [NSNumber numberWithBool: YES], PRNewLineKey,
        @"Writing file", PRDescriptionKey,
        nil];

#ifdef OTX_CLI
    [iController reportProgress: progDict];
#else
    [iController performSelectorOnMainThread: @selector(reportProgress:)
        withObject: progDict waitUntilDone: NO];
#endif

    [progDict release];

    // Create output file.
    if (![self printLinesFromList: iPlainLineListHead])
    {
        return NO;
    }

    if (iOpts.dataSections)
    {
        if (![self printDataSections])
        {
            return NO;
        }
    }

    progDict = [[NSMutableDictionary alloc] initWithObjectsAndKeys:
        [NSNumber numberWithBool: YES], PRCompleteKey,
        nil];

#ifdef OTX_CLI
    [iController reportProgress: progDict];
#else
    [iController performSelectorOnMainThread: @selector(reportProgress:)
        withObject: progDict waitUntilDone: NO];
#endif

    [progDict release];

    return YES;
}

//  populateLineLists
// ----------------------------------------------------------------------------

- (BOOL)populateLineLists
{
    Line64* thePrevVerboseLine  = NULL;
    Line64* thePrevPlainLine    = NULL;

    // Read __text lines.
    [self populateLineList: &iVerboseLineListHead verbosely: YES
        fromSection: "__text" afterLine: &thePrevVerboseLine
        includingPath: YES];

    [self populateLineList: &iPlainLineListHead verbosely: NO
        fromSection: "__text" afterLine: &thePrevPlainLine
        includingPath: YES];

    // Read __coalesced_text lines.
    if (iCoalTextSect.size)
    {
        [self populateLineList: &iVerboseLineListHead verbosely: YES
            fromSection: "__coalesced_text" afterLine: &thePrevVerboseLine
            includingPath: NO];

        [self populateLineList: &iPlainLineListHead verbosely: NO
            fromSection: "__coalesced_text" afterLine: &thePrevPlainLine
            includingPath: NO];
    }

    // Read __textcoal_nt lines.
    if (iCoalTextNTSect.size)
    {
        [self populateLineList: &iVerboseLineListHead verbosely: YES
            fromSection: "__textcoal_nt" afterLine: &thePrevVerboseLine
            includingPath: NO];

        [self populateLineList: &iPlainLineListHead verbosely: NO
            fromSection: "__textcoal_nt" afterLine: &thePrevPlainLine
            includingPath: NO];
    }

    // Connect the 2 lists.
    Line64* verboseLine = iVerboseLineListHead;
    Line64* plainLine   = iPlainLineListHead;

    while (verboseLine && plainLine)
    {
        verboseLine->alt    = plainLine;
        plainLine->alt      = verboseLine;

        verboseLine = verboseLine->next;
        plainLine   = plainLine->next;
    }

    // Optionally insert md5.
    if (iOpts.checksum)
        [self insertMD5];

    return YES;
}

//  populateLineList:verbosely:fromSection:afterLine:includingPath:
// ----------------------------------------------------------------------------

- (BOOL)populateLineList: (Line64**)inList
               verbosely: (BOOL)inVerbose
             fromSection: (char*)inSectionName
               afterLine: (Line64**)inLine
           includingPath: (BOOL)inIncludePath
{
    char cmdString[MAX_UNIBIN_OTOOL_CMD_SIZE] = "";
    NSString* otoolPath = [self pathForTool: @"otool"];
    NSUInteger otoolPathLength = [otoolPath length];
    size_t archStringLength = strlen(iArchString);

    // otool freaks out when somebody says -arch and it's not a unibin.
    if (iExeIsFat)
    {
        // Bail if it won't fit.
        if ((otoolPathLength + archStringLength + 7 /* strlen(" -arch ") */) >= MAX_UNIBIN_OTOOL_CMD_SIZE)
            return NO;

        snprintf(cmdString, MAX_UNIBIN_OTOOL_CMD_SIZE,
            "%s -arch %s", [otoolPath UTF8String], iArchString);
    }
    else
    {
        // Bail if it won't fit.
        if (otoolPathLength >= MAX_UNIBIN_OTOOL_CMD_SIZE)
            return NO;

        strncpy(cmdString, [otoolPath UTF8String], otoolPathLength);
    }

    NSString* oPath = [iOFile path];
    NSString* otoolString = [NSString stringWithFormat:
        @"%s %s -s __TEXT %s \"%@\"%s", cmdString,
        (inVerbose) ? "-V" : "-v", inSectionName, oPath,
        (inIncludePath) ? "" : " | sed '1 d'"];
    FILE* otoolPipe = popen(UTF8STRING(otoolString), "r");

    if (!otoolPipe)
    {
        fprintf(stderr, "otx: unable to open %s otool pipe\n",
            (inVerbose) ? "verbose" : "plain");
        return NO;
    }

    char theCLine[MAX_LINE_LENGTH];

    while (fgets(theCLine, MAX_LINE_LENGTH, otoolPipe))
    {
        // Many thanx to Peter Hosey for the calloc speed test.
        // http://boredzo.org/blog/archives/2006-11-26/calloc-vs-malloc

        Line64* theNewLine  = calloc(1, sizeof(Line64));

        theNewLine->length  = strlen(theCLine);
        theNewLine->chars   = malloc(theNewLine->length + 1);
        strncpy(theNewLine->chars, theCLine,
            theNewLine->length + 1);

        // Add the line to the list.
        InsertLineAfter(theNewLine, *inLine, inList);

        *inLine = theNewLine;
    }

    if (pclose(otoolPipe) == -1)
    {
        perror((inVerbose) ? "otx: unable to close verbose otool pipe" :
            "otx: unable to close plain otool pipe");
        return NO;
    }

    return YES;
}

#pragma mark -
//  gatherLineInfos
// ----------------------------------------------------------------------------
//  To make life easier as we make changes to the lines, whatever info we need
//  is harvested early here.

- (void)gatherLineInfos
{
    Line64*         theLine     = iPlainLineListHead;
    uint32_t          progCounter = 0;

    while (theLine)
    {
        if (!(progCounter % (PROGRESS_FREQ * 5)))
        {
            if (gCancel == YES)
                return;

//            [NSThread sleepForTimeInterval: 0.0];
        }

        if (LineIsCode(theLine->chars))
        {
            theLine->info.isCode = YES;
            theLine->info.address = AddressFromLine(theLine->chars);
            CodeFromLine(theLine);  // FIXME: return a value like the cool kids do.

            if (theLine->alt)
            {
                theLine->alt->info.isCode = theLine->info.isCode;
                theLine->alt->info.address = theLine->info.address;
                theLine->alt->info.codeLength = theLine->info.codeLength;
                memcpy(theLine->alt->info.code, theLine->info.code,
                    sizeof(theLine->info.code));
            }

            CheckThunk(theLine);
        }
        else    // not code...
        {
            if (strstr(theLine->chars, "(__TEXT,__coalesced_text)"))
                iEndOfText  = iCoalTextSect.s.addr + iCoalTextSect.s.size;
            else if (strstr(theLine->chars, "(__TEXT,__textcoal_nt)"))
                iEndOfText  = iCoalTextNTSect.s.addr + iCoalTextNTSect.s.size;
        }

        theLine = theLine->next;
        progCounter++;
        iNumLines++;
    }

    iEndOfText  = iTextSect.s.addr + iTextSect.s.size;
}

//  findFunctions
// ----------------------------------------------------------------------------

- (void)findFunctions
{
    // Loop once to flag all funcs.
    Line64* theLine = iPlainLineListHead;

    while (theLine)
    {
        theLine->info.isFunction    = LineIsFunction(theLine);

        if (theLine->alt)
            theLine->alt->info.isFunction   = theLine->info.isFunction;

        theLine = theLine->next;
    }

    // Loop again to allocate funcInfo's.
    theLine = iPlainLineListHead;
    iLineArray = calloc(iNumLines, sizeof(Line64*));
    iNumCodeLines = 0;

    while (theLine)
    {
        if (theLine->info.isFunction)
        {
            iNumFuncInfos++;
            iFuncInfos  = realloc(iFuncInfos,
                sizeof(Function64Info) * iNumFuncInfos);

            uint32_t  genericFuncNum  = 0;

            if (theLine->prev && theLine->prev->info.isCode)
                genericFuncNum  = ++iCurrentGenericFuncNum;

            iFuncInfos[iNumFuncInfos - 1]   = (Function64Info)
                {theLine->info.address, NULL, 0, genericFuncNum};
        }

        if (theLine->info.isCode)
            iLineArray[iNumCodeLines++] = theLine;

        theLine = theLine->next;
    }
}

//  processLine:
// ----------------------------------------------------------------------------

- (void)processLine: (Line64*)ioLine;
{
    if (!strlen(ioLine->chars))
        return;

    // otool is inconsistent in printing section headers. Sometimes it
    // prints "Contents of (x)" and sometimes just "(x)". We'll take this
    // opportunity to use the shorter version in all cases.
    char*   theContentsString       = "Contents of ";
    UInt8   theContentsStringLength = strlen(theContentsString);
    char*   theTextSegString        = "(__TEXT,__";

    // Kill the "Contents of" if it exists.
    if (strstr(ioLine->chars, theContentsString))
    {
        char    theTempLine[MAX_LINE_LENGTH];

        theTempLine[0]  = '\n';
        theTempLine[1]  = 0;

        strncat(theTempLine, &ioLine->chars[theContentsStringLength],
            strlen(&ioLine->chars[theContentsStringLength]));

        ioLine->length  = strlen(theTempLine);
        strncpy(ioLine->chars, theTempLine, ioLine->length + 1);

        return;
    }
    else if (strstr(ioLine->chars, theTextSegString))
    {
        if (strstr(ioLine->chars, "__coalesced_text)"))
        {
            iEndOfText      = iCoalTextSect.s.addr + iCoalTextSect.s.size;
            iLocalOffset    = 0;
        }
        else if (strstr(ioLine->chars, "__textcoal_nt)"))
        {
            iEndOfText      = iCoalTextNTSect.s.addr + iCoalTextNTSect.s.size;
            iLocalOffset    = 0;
        }

        char    theTempLine[MAX_LINE_LENGTH];

        theTempLine[0]  = '\n';
        theTempLine[1]  = 0;

        strncat(theTempLine, ioLine->chars, strlen(ioLine->chars));

        ioLine->length++;
        ioLine->chars = (char*)realloc(ioLine->chars, ioLine->length + 1);
        strncpy(ioLine->chars, theTempLine, ioLine->length + 1);

        return;
    }

    // If we got here, we have a symbol name.
    if (iOpts.demangleCppNames)
    {
        if (strstr(ioLine->chars, "__Z") == ioLine->chars)
        {
            char demangledName[MAX_LINE_LENGTH];

            // Line should end with ":\n". Terminate over the colon if it exists.
            if (ioLine->chars[ioLine->length - 2] == ':')
                ioLine->chars[ioLine->length - 2] = 0;
            else
                ioLine->chars[ioLine->length - 1] = 0;

            NSFileHandle* filtWrite = [iCPFiltInputPipe fileHandleForWriting];
            NSFileHandle* filtRead = [iCPFiltOutputPipe fileHandleForReading];
            NSMutableData* dataToWrite = [NSMutableData dataWithBytes: ioLine->chars
                                                               length: strlen(ioLine->chars)];

            [dataToWrite appendBytes: "\n"
                              length: 1];

            @try {
                [filtWrite writeData: dataToWrite];
            }
            @catch (NSException* e) {
                NSLog(@"otx: [Exe64Processor processLine:] failed to write to c++filt: %@", [e reason]);
            }

            NSData* readData = nil;

            @try {
                readData = [filtRead availableData];
            }
            @catch (NSException* e) {
                NSLog(@"otx: [Exe64Processor processLine:] failed to read from c++filt: %@", [e reason]);
            }

            [readData getBytes: demangledName];

            if (readData != nil)
            {
                NSUInteger demangledDataLength = [readData length];
                NSUInteger demangledStringLength = MIN(demangledDataLength, MAX_LINE_LENGTH - 1);

                if (demangledStringLength < demangledDataLength)
                    NSLog(@"otx: demangled C++ name is too large. Increase MAX_LINE_LENGTH to %lu.\n"
                           "Name demangling will now go off the rails.", demangledDataLength);

                // Get the string and terminate it.
                [readData getBytes: demangledName
                            length: demangledStringLength];
                demangledName[demangledStringLength] = 0;

                free(ioLine->chars);
                ioLine->length = demangledStringLength;
                ioLine->chars = malloc(ioLine->length + 1);

                strncpy(ioLine->chars, demangledName, ioLine->length + 1);
            }
            else
            {
                NSLog(@"otx: [Exe64Processor processLine:] got nil data from c++filt");
            }
        }
    }
}

//  processCodeLine:
// ----------------------------------------------------------------------------

- (void)processCodeLine: (Line64**)ioLine;
{
    if (!ioLine || !(*ioLine) || !((*ioLine)->chars))
    {
        fprintf(stderr, "otx: tried to process NULL code line\n");
        return;
    }

    ChooseLine(ioLine);

    uint32_t  theOrigLength           = (*ioLine)->length;
    char    localOffsetString[9]    = {0};
    char    theAddressCString[17]    = {0};
    char    theMnemonicCString[20]  = {0};

    char    addrSpaces[MAX_FIELD_SPACING] = MAX_FIELD_SPACES;
    char    instSpaces[MAX_FIELD_SPACING] = MAX_FIELD_SPACES;
    char    mnemSpaces[MAX_FIELD_SPACING] = MAX_FIELD_SPACES;
    char    opSpaces[MAX_FIELD_SPACING] = MAX_FIELD_SPACES;
    char    commentSpaces[MAX_FIELD_SPACING] = MAX_FIELD_SPACES;

    char    theOrigCommentCString[MAX_COMMENT_LENGTH];
    char    theCommentCString[MAX_COMMENT_LENGTH];

    theOrigCommentCString[0]    = 0;
    theCommentCString[0]        = 0;

    // Swap in saved registers if necessary
    BOOL    needNewLine = RestoreRegisters(*ioLine);

    iLineOperandsCString[0] = 0;

    char*   origFormatString    = "%s\t%s\t%s%n";
    uint32_t  consumedAfterOp     = 0;

    // The address and mnemonic always exist, separated by a tab.
    sscanf((*ioLine)->chars, origFormatString, theAddressCString,
        theMnemonicCString, iLineOperandsCString, &consumedAfterOp);

    // If we didn't grab everything up to the newline, there's a comment
    // remaining. Copy it, starting after the preceding tab.
    if (consumedAfterOp && consumedAfterOp < theOrigLength - 1)
    {
        if (iLineOperandsCString[0] == '*' &&
            (iLineOperandsCString[1] == '+' || iLineOperandsCString[1] == '-'))
        {   // ObjC method call with whitespace
            char    dummyAddressCString[17] = {0};
            char    dummyMnemonicCString[20] = {0};

            sscanf((*ioLine)->chars, "%s\t%s\t%[^\t\n]s", dummyAddressCString,
                dummyMnemonicCString, iLineOperandsCString);
        }
        else    // regular comment
        {
            uint32_t  origCommentLength   = theOrigLength - consumedAfterOp - 1;

            strncpy(theOrigCommentCString, (*ioLine)->chars + consumedAfterOp + 1,
                origCommentLength);

            // Add the null terminator.
            theOrigCommentCString[origCommentLength - 1]    = 0;
        }
    }

    char theCodeCString[32] = {0};
    UInt8* inBuffer = (*ioLine)->info.code;
    UInt8 i;

    char codeFormatString[61] = "%02x%02x%02x%02x%02x%02x%02x%02x%02x%02x%02x%02x%02x%02x%02x";

    if ((*ioLine)->info.codeLength > 15)
    {
        fprintf(stderr, "otx: surprisingly long instruction of %u bytes at 0x%016llx\n", (*ioLine)->info.codeLength, (*ioLine)->info.address);
        return;
    }

    codeFormatString[(*ioLine)->info.codeLength * 4] = 0;

    snprintf(theCodeCString, 31, codeFormatString,
        inBuffer[0], inBuffer[1], inBuffer[2], inBuffer[3],
        inBuffer[4], inBuffer[5], inBuffer[6], inBuffer[7],
        inBuffer[8], inBuffer[9], inBuffer[10], inBuffer[11],
        inBuffer[12], inBuffer[13], inBuffer[14]);

    i = iFieldWidths.instruction - (*ioLine)->info.codeLength * 2;
    mnemSpaces[i - 1] = 0;

    i = iFieldWidths.mnemonic - strlen(theMnemonicCString);
    opSpaces[i - 1] = 0;

    // Terminate commentSpaces based on operands field width.
    if (iLineOperandsCString[0] && theOrigCommentCString[0])
    {
        size_t opLength = strlen(iLineOperandsCString);

        if (opLength < iFieldWidths.operands)
        {
            i = iFieldWidths.operands - opLength;
            commentSpaces[i - 1] = 0;
        }
        else
            commentSpaces[0] = 0;
    }
    else
    {
        commentSpaces[0] = 0;
    }

    // Remove "; symbol stub for: "
    if (theOrigCommentCString[0])
    {
        char*   theSubstring    =
            strstr(theOrigCommentCString, "; symbol stub for: ");

        if (theSubstring)
            strncpy(theCommentCString, &theOrigCommentCString[19],
                strlen(&theOrigCommentCString[19]) + 1);
        else
            strncpy(theCommentCString, theOrigCommentCString,
                strlen(theOrigCommentCString) + 1);
    }

    BOOL    needFuncName = NO;
    char    theMethCName[1000];

    theMethCName[0] = 0;

    // Check if this is the beginning of a function.
    if ((*ioLine)->info.isFunction)
    {
        // Squash the new block flag, just in case.
        iEnteringNewBlock = NO;

        // New function, new local offset count and current func.
        iLocalOffset    = 0;
        iCurrentFuncPtr = (*ioLine)->info.address;

        // Try to build the method name.
        Method64Info* methodInfoPtr   = NULL;
        Method64Info  methodInfo;

        if (GetObjcMethodFromAddress(&methodInfoPtr, iCurrentFuncPtr))
        {
            methodInfo  = *methodInfoPtr;

            char*   className   = NULL;

            if (methodInfo.oc_class.data)
            {
                objc2_class_ro_t* roData = (objc2_class_ro_t*)(iDataSect.contents +
                    (uintptr_t)(methodInfo.oc_class.data - iDataSect.s.addr));

                UInt64 name = roData->name;

                if (iSwapped)
                    name = OSSwapInt64(name);

                className = GetPointer(name, NULL);
            }

//            char*   catName     = NULL;

            /*if (theSwappedInfo.oc_cat.category_name)
            {
                className   = GetPointer(
                    theSwappedInfo.oc_cat.class_name, NULL);
                catName     = GetPointer(
                    theSwappedInfo.oc_cat.category_name, NULL);
            }
            else if (theSwappedInfo.oc_class.data.name)
            {
                className   = GetPointer(
                    theSwappedInfo.oc_class.name, NULL);
            }*/

            if (className)
            {
                char*   selName = GetPointer(methodInfo.m.name, NULL);

                if (selName)
                {
                    if (!methodInfo.m.types)
                        return;

                    char*   methTypes   =
                        GetPointer(methodInfo.m.types, NULL);

                    if (methTypes)
                    {
                        char    returnCType[MAX_TYPE_STRING_LENGTH];

                        returnCType[0]  = 0;

                        [self decodeMethodReturnType: methTypes
                            output: returnCType];

/*                        if (catName)
                        {
                            char*   methNameFormat  = iOpts.returnTypes ?
                                "\n%1$c(%5$s)[%2$s(%3$s) %4$s]\n" :
                                "\n%c[%s(%s) %s]\n";

                            snprintf(theMethCName, 1000,
                                methNameFormat,
                                (theSwappedInfo.inst) ? '-' : '+',
                                className, catName, selName, returnCType);
                        }
                        else*/
                        //{
                            char*   methNameFormat  = iOpts.returnTypes ?
                                "\n%1$c(%4$s)[%2$s %3$s]\n" : "\n%c[%s %s]\n";

                            snprintf(theMethCName, 1000,
                                methNameFormat,
                                (methodInfo.inst) ? '-' : '+',
                                className, selName, returnCType);
                        //}
                    }
                }
            }
        }   // if (GetObjcMethodFromAddress(&theSwappedInfoPtr, mCurrentFuncPtr))

        // Add or replace the method name if possible, else add '\n'.
        if ((*ioLine)->prev && (*ioLine)->prev->info.isCode)    // prev line is code
        {
            if (theMethCName[0])
            {
                Line64* theNewLine  = malloc(sizeof(Line64));

                theNewLine->length  = strlen(theMethCName);
                theNewLine->chars   = malloc(theNewLine->length + 1);

                strncpy(theNewLine->chars, theMethCName,
                    theNewLine->length + 1);
                InsertLineBefore(theNewLine, *ioLine, &iPlainLineListHead);
            }
            else if ((*ioLine)->info.address == iAddrDyldStubBindingHelper)
            {
                Line64* theNewLine  = malloc(sizeof(Line64));
                char*   theDyldName = "\ndyld_stub_binding_helper:\n";

                theNewLine->length  = strlen(theDyldName);
                theNewLine->chars   = malloc(theNewLine->length + 1);

                strncpy(theNewLine->chars, theDyldName, theNewLine->length + 1);
                InsertLineBefore(theNewLine, *ioLine, &iPlainLineListHead);
            }
            else if ((*ioLine)->info.address == iAddrDyldFuncLookupPointer)
            {
                Line64* theNewLine  = malloc(sizeof(Line64));
                char*   theDyldName = "\n__dyld_func_lookup:\n";

                theNewLine->length  = strlen(theDyldName);
                theNewLine->chars   = malloc(theNewLine->length + 1);

                strncpy(theNewLine->chars, theDyldName, theNewLine->length + 1);
                InsertLineBefore(theNewLine, *ioLine, &iPlainLineListHead);
            }
            else
                needFuncName = YES;
        }
        else    // prev line is not code
        {
            if (theMethCName[0])
            {
                Line64* theNewLine  = malloc(sizeof(Line64));

                theNewLine->length  = strlen(theMethCName);
                theNewLine->chars   = malloc(theNewLine->length + 1);

                strncpy(theNewLine->chars, theMethCName,
                    theNewLine->length + 1);
                ReplaceLine((*ioLine)->prev, theNewLine, &iPlainLineListHead);
            }
            else
            {   // theMethName sux, add '\n' to otool's method name.
                char    theNewLine[MAX_LINE_LENGTH];

                if ((*ioLine)->prev->chars[0] != '\n')
                {
                    theNewLine[0]   = '\n';
                    theNewLine[1]   = 0;
                }
                else
                    theNewLine[0]   = 0;

                strncat(theNewLine, (*ioLine)->prev->chars,
                    (*ioLine)->prev->length);

                free((*ioLine)->prev->chars);
                (*ioLine)->prev->length = strlen(theNewLine);
                (*ioLine)->prev->chars  = malloc((*ioLine)->prev->length + 1);
                strncpy((*ioLine)->prev->chars, theNewLine,
                    (*ioLine)->prev->length + 1);
            }
        }

        ResetRegisters(*ioLine);
    }   // if ((*ioLine)->info.isFunction)

    // Find a comment if necessary.
    if (!theCommentCString[0])
    {
        CommentForLine(*ioLine);

        uint32_t  origCommentLength   = strlen(iLineCommentCString);

        if (origCommentLength)
        {
            char    tempComment[MAX_COMMENT_LENGTH];
            uint32_t  i, j = 0;

            // Escape newlines, carriage returns and tabs.
            for (i = 0; i < origCommentLength; i++)
            {
                if (iLineCommentCString[i] == '\n')
                {
                    tempComment[j++]    = '\\';
                    tempComment[j++]    = 'n';
                }
                else if (iLineCommentCString[i] == '\r')
                {
                    tempComment[j++]    = '\\';
                    tempComment[j++]    = 'r';
                }
                else if (iLineCommentCString[i] == '\t')
                {
                    tempComment[j++]    = '\\';
                    tempComment[j++]    = 't';
                }
                else
                    tempComment[j++]    = iLineCommentCString[i];
            }

            // Add the null terminator.
            tempComment[j]  = 0;

            if (iLineOperandsCString[0])
                strncpy(theCommentCString, tempComment,
                    strlen(tempComment) + 1);
            else
                strncpy(iLineOperandsCString, tempComment,
                    strlen(tempComment) + 1);

            // Terminate commentSpaces based on operands field width.
            size_t opLength = strlen(iLineOperandsCString);

            if (opLength < iFieldWidths.operands)
            {
                commentSpaces[0] = ' ';
                UInt8 k = iFieldWidths.operands - opLength;
                commentSpaces[k - 1]    = 0;
            }
            else
            {
                commentSpaces[0] = 0;
            }
        }
    }   // if (!theCommentCString[0])
    else    // otool gave us a comment.
    {
        // Optionally modify otool's comment.
        if (iOpts.verboseMsgSends)
            CommentForMsgSendFromLine(theCommentCString, *ioLine);
    }

    // Demangle operands if necessary.
    if (iLineOperandsCString[0] && iOpts.demangleCppNames)
    {
        if (strstr(iLineOperandsCString, "__Z") == iLineOperandsCString)
        {
            char demangledName[MAX_OPERANDS_LENGTH];

            NSFileHandle* filtWrite = [iCPFiltInputPipe fileHandleForWriting];
            NSFileHandle* filtRead = [iCPFiltOutputPipe fileHandleForReading];
            NSMutableData* dataToWrite = [NSMutableData dataWithBytes: iLineOperandsCString
                                                               length: strlen(iLineOperandsCString)];

            [dataToWrite appendBytes: "\n"
                              length: 1];

            @try {
                [filtWrite writeData: dataToWrite];
            }
            @catch (NSException* e) {
                NSLog(@"otx: [Exe64Processor processCodeLine:] failed to write operands to c++filt: %@", [e reason]);
            }

            NSData* readData = nil;

            @try {
                readData = [filtRead availableData];
            }
            @catch (NSException* e) {
                NSLog(@"otx: [Exe64Processor processCodeLine:] failed to read operands from c++filt: %@", [e reason]);
            }

            if (readData != nil)
            {
                NSUInteger demangledDataLength = [readData length];
                NSUInteger demangledStringLength = MIN(demangledDataLength, MAX_OPERANDS_LENGTH - 1);

                if (demangledStringLength < demangledDataLength)
                    NSLog(@"otx: demangled C++ name is too large. Increase MAX_OPERANDS_LENGTH to %lu.\n"
                           "Name demangling will now go off the rails.", demangledDataLength);

                [readData getBytes: demangledName
                            length: demangledStringLength];

                // Remove the trailing newline and terminate.
                demangledStringLength--;
                demangledName[demangledStringLength] = 0;
                strncpy(iLineOperandsCString, demangledName, demangledStringLength + 1);
            }
            else
            {
                NSLog(@"otx: [Exe64Processor processCodeLine:] got nil operands data from c++filt");
            }
        }
    }

    // Demangle comment if necessary.
    if (theCommentCString[0] && iOpts.demangleCppNames)
    {
        if (strstr(theCommentCString, "__Z") == theCommentCString)
        {
            char    demangledName[MAX_COMMENT_LENGTH];

            NSFileHandle* filtWrite = [iCPFiltInputPipe fileHandleForWriting];
            NSFileHandle* filtRead = [iCPFiltOutputPipe fileHandleForReading];
            NSMutableData* dataToWrite = [NSMutableData dataWithBytes: theCommentCString
                                                               length: strlen(theCommentCString)];

            [dataToWrite appendBytes: "\n"
                              length: 1];

            @try {
                [filtWrite writeData: dataToWrite];
            }
            @catch (NSException* e) {
                NSLog(@"otx: [Exe64Processor processCodeLine:] failed to write comment to c++filt: %@", [e reason]);
            }

            NSData* readData = nil;

            @try {
                readData = [filtRead availableData];
            }
            @catch (NSException* e) {
                NSLog(@"otx: [Exe64Processor processCodeLine:] failed to read comment from c++filt: %@", [e reason]);
            }

            if (readData != nil)
            {
                NSUInteger demangledDataLength = [readData length];
                NSUInteger demangledStringLength = MIN(demangledDataLength, MAX_COMMENT_LENGTH - 1);

                if (demangledStringLength < demangledDataLength)
                    NSLog(@"otx: demangled C++ name is too large. Increase MAX_COMMENT_LENGTH to %lu.\n"
                           "Name demangling will now go off the rails.", demangledDataLength);

                [readData getBytes: demangledName
                            length: demangledStringLength];

                // Remove the trailing newline and terminate.
                demangledStringLength--;
                demangledName[demangledStringLength] = 0;
                strncpy(theCommentCString, demangledName, demangledStringLength + 1);
            }
            else
            {
                NSLog(@"otx: [Exe64Processor processCodeLine:] got nil comment data from c++filt");
            }
        }
    }

    // Optionally add local offset.
    if (iOpts.localOffsets)
    {
        // Build a right-aligned string  with a '+' in it.
        snprintf((char*)&localOffsetString, iFieldWidths.offset,
            "%6u", iLocalOffset);

        // Find the space that's followed by a nonspace.
        // *Reverse count to optimize for short functions.
        for (i = 0; i < 5; i++)
        {
            if (localOffsetString[i] == 0x20 &&
                localOffsetString[i + 1] != 0x20)
            {
                localOffsetString[i] = '+';
                break;
            }
        }

        if (theCodeCString)
            iLocalOffset += strlen(theCodeCString) / 2;

        // Terminate addrSpaces based on offset field width.
        i   = iFieldWidths.offset - 6;
        addrSpaces[i - 1] = 0;
    }

    // Terminate instSpaces based on address field width.
    i   = iFieldWidths.address - 16;
    instSpaces[i - 1] = 0;

    // Insert a generic function name if needed.
    if (needFuncName)
    {
        Function64Info  searchKey   = {(*ioLine)->info.address, NULL, 0, 0};
        Function64Info* funcInfo    = bsearch(&searchKey,
            iFuncInfos, iNumFuncInfos, sizeof(Function64Info),
            (COMPARISON_FUNC_TYPE)Function64_Info_Compare);

        // sizeof(UINT32_MAX) + '\n' * 2 + ':' + null term
        UInt8   maxlength   = ANON_FUNC_BASE_LENGTH + 14;
        Line64* funcName    = calloc(1, sizeof(Line64));

        funcName->chars     = malloc(maxlength);

        // Hack Alert: In the case that we have too few funcInfo's, print
        // \nAnon???. Of course, we'll still intermittently crash later, but
        // when we don't, the output will look pretty.
        // Replace "if (funcInfo)" from rev 319 around this...
        if (funcInfo)
            funcName->length    = snprintf(funcName->chars, maxlength,
                "\n%s%d:\n", ANON_FUNC_BASE, funcInfo->genericFuncNum);
        else
            funcName->length    = snprintf(funcName->chars, maxlength,
                "\n%s???:\n", ANON_FUNC_BASE);

        InsertLineBefore(funcName, *ioLine, &iPlainLineListHead);
    }

    // Finally, assemble the new string.
    char    finalFormatCString[MAX_FORMAT_LENGTH];
    uint32_t  formatMarker    = 0;

    if (needNewLine)
    {
        formatMarker++;
        finalFormatCString[0]   = '\n';
        finalFormatCString[1]   = 0;
    }
    else
        finalFormatCString[0]   = 0;

    if (iOpts.localOffsets)
        formatMarker += snprintf(&finalFormatCString[formatMarker],
            10, "%s", "%s %s");

    if (iLineOperandsCString[0])
    {
        if (theCommentCString[0])
            snprintf(&finalFormatCString[formatMarker],
                30, "%s", "%s %s%s %s%s %s%s %s%s\n");
        else
            snprintf(&finalFormatCString[formatMarker],
                30, "%s", "%s %s%s %s%s %s%s\n");
    }
    else
        snprintf(&finalFormatCString[formatMarker],
            30, "%s", "%s %s%s %s%s\n");

    char    theFinalCString[MAX_LINE_LENGTH] = "";

    if (iOpts.localOffsets)
        snprintf(theFinalCString, MAX_LINE_LENGTH - 1,
            finalFormatCString, localOffsetString,
            addrSpaces, theAddressCString,
            instSpaces, theCodeCString,
            mnemSpaces, theMnemonicCString,
            opSpaces, iLineOperandsCString,
            commentSpaces, theCommentCString);
    else
        snprintf(theFinalCString, MAX_LINE_LENGTH - 1,
            finalFormatCString, theAddressCString,
            instSpaces, theCodeCString,
            mnemSpaces, theMnemonicCString,
            opSpaces, iLineOperandsCString,
            commentSpaces, theCommentCString);

    free((*ioLine)->chars);

    if (iOpts.separateLogicalBlocks && iEnteringNewBlock &&
        theFinalCString[0] != '\n')
    {
        (*ioLine)->length   = strlen(theFinalCString) + 1;
        (*ioLine)->chars    = malloc((*ioLine)->length + 1);
        (*ioLine)->chars[0] = '\n';
        strncpy(&(*ioLine)->chars[1], theFinalCString, (*ioLine)->length);
    }
    else
    {
        (*ioLine)->length   = strlen(theFinalCString);
        (*ioLine)->chars    = malloc((*ioLine)->length + 1);
        strncpy((*ioLine)->chars, theFinalCString, (*ioLine)->length + 1);
    }

    // The test above can fail even if mEnteringNewBlock was YES, so we
    // should reset it here instead.
    iEnteringNewBlock = NO;

    UpdateRegisters(*ioLine);
    PostProcessCodeLine(ioLine);

    // Possibly prepend a \n to the following line.
    if (CodeIsBlockJump((*ioLine)->info.code))
        iEnteringNewBlock = YES;
}

//  addressFromLine:
// ----------------------------------------------------------------------------

- (UInt64)addressFromLine: (const char*)inLine
{
    // sanity check
    if ((inLine[0] < '0' || inLine[0] > '9') &&
        (inLine[0] < 'a' || inLine[0] > 'f'))
        return 0;

    UInt64  theAddress  = 0;

    sscanf(inLine, "%016llx", &theAddress);
    return theAddress;
}

//  lineIsCode:
// ----------------------------------------------------------------------------
//  Line is code if first 16 chars are hex numbers and 17th is tab.

- (BOOL)lineIsCode: (const char*)inLine
{
    if (strlen(inLine) < 18)
        return NO;

    UInt16  i;

    for (i = 0 ; i < 16; i++)
    {
        if ((inLine[i] < '0' || inLine[i] > '9') &&
            (inLine[i] < 'a' || inLine[i] > 'f'))
            return NO;
    }

    return (inLine[16] == '\t');
}

//  chooseLine:
// ----------------------------------------------------------------------------
//  Subclasses may override.

- (void)chooseLine: (Line64**)ioLine
{}

#pragma mark -
//  printDataSections
// ----------------------------------------------------------------------------
//  Append data sections to output file.

- (BOOL)printDataSections
{
    FILE*   outFile = NULL;

    if (iOutputFilePath)
        outFile = fopen(UTF8STRING(iOutputFilePath), "a");
    else
        outFile = stdout;

    if (!outFile)
    {
        perror("otx: unable to open output file");
        return NO;
    }

    if (iDataSect.size)
    {
        if (fprintf(outFile, "\n(__DATA,__data) section\n") < 0)
        {
            perror("otx: unable to write to output file");
            return NO;
        }

        [self printDataSection: &iDataSect toFile: outFile];
    }

    if (iCoalDataSect.size)
    {
        if (fprintf(outFile, "\n(__DATA,__coalesced_data) section\n") < 0)
        {
            perror("otx: unable to write to output file");
            return NO;
        }

        [self printDataSection: &iCoalDataSect toFile: outFile];
    }

    if (iCoalDataNTSect.size)
    {
        if (fprintf(outFile, "\n(__DATA,__datacoal_nt) section\n") < 0)
        {
            perror("otx: unable to write to output file");
            return NO;
        }

        [self printDataSection: &iCoalDataNTSect toFile: outFile];
    }

    if (iOutputFilePath)
    {
        if (fclose(outFile) != 0)
        {
            perror("otx: unable to close output file");
            return NO;
        }
    }

    return YES;
}

#define _64_BIT_ADDRESS_COLUMN_LENGTH_ 18

//  printDataSection:toFile:
// ----------------------------------------------------------------------------

- (void)printDataSection: (section_info_64*)inSect
                  toFile: (FILE*)outFile;
{
    uint32_t bytesLeft;
    uint32_t i, j, k;
    uint32_t theDataSize = (uint32_t)inSect->size;
    char theLineCString[80];
    char* theMachPtr = (char*)iMachHeaderPtr;

    theLineCString[0] = 0;

    for (i = 0; i < theDataSize; i += 16)
    {
        bytesLeft = theDataSize - i;

        unsigned char theASCIIData[20] = {0};

        if (bytesLeft < 16) // last line
        {
            theLineCString[0] = 0;
            snprintf(theLineCString, _64_BIT_ADDRESS_COLUMN_LENGTH_ + 1 ,"%016llx |", inSect->s.addr + i);

            unsigned char theHexData[17] = {0};

            memcpy(theHexData, (const void*)(theMachPtr + inSect->s.offset + i), bytesLeft);
            memcpy(theASCIIData, theHexData, bytesLeft);

            j   = _64_BIT_ADDRESS_COLUMN_LENGTH_;

            for (k = 0; k < bytesLeft; k++)
            {
                if ((k % 4) == 0)
                    theLineCString[j++] = 0x20;

                snprintf(&theLineCString[j], 4, "%02x", theHexData[k]);
                j += 2;

                if (theASCIIData[k] < 0x20 || theASCIIData[k] == 0x7f)
                    theASCIIData[k] = '.';
            }

            // Append spaces.
            for (; j < _64_BIT_ADDRESS_COLUMN_LENGTH_ + 38; j++)
                theLineCString[j] = 0x20;

            // Append ASCII chars.
            snprintf(&theLineCString[j], 80, "%s\n", theASCIIData);
        }
        else    // first lines
        {           
            uint32_t* theHexPtr = (uint32_t*)(theMachPtr + inSect->s.offset + i);
            UInt8 j;

            memcpy(theASCIIData, (const void*)(theMachPtr + inSect->s.offset + i), 16);

            for (j = 0; j < 16; j++)
                if (theASCIIData[j] < 0x20 || theASCIIData[j] == 0x7f)
                    theASCIIData[j] = '.';

#if TARGET_RT_LITTLE_ENDIAN
            theHexPtr[0] = OSSwapInt32(theHexPtr[0]);
            theHexPtr[1] = OSSwapInt32(theHexPtr[1]);
            theHexPtr[2] = OSSwapInt32(theHexPtr[2]);
            theHexPtr[3] = OSSwapInt32(theHexPtr[3]);
#endif

            snprintf(theLineCString, sizeof(theLineCString),
                "%016llx | %08x %08x %08x %08x  %s\n",
                inSect->s.addr + i,
                theHexPtr[0], theHexPtr[1], theHexPtr[2], theHexPtr[3],
                theASCIIData);
        }

        if (fprintf(outFile, "%s", theLineCString) < 0)
        {
            perror("otx: [Exe64Processor printDataSection:toFile:]: "
                "unable to write to output file");
            return;
        }
    }
}

#pragma mark -
//  selectorForMsgSend:fromLine:
// ----------------------------------------------------------------------------
//  Subclasses may override.

- (char*)selectorForMsgSend: (char*)outComment
                   fromLine: (Line64*)inLine
{
    return NULL;
}

#pragma mark -
//  insertMD5
// ----------------------------------------------------------------------------

- (void)insertMD5
{
    NSString* md5String = [self generateMD5String];

    Line64* newLine = calloc(1, sizeof(Line64));
    const char* utf8String = [md5String UTF8String];

    newLine->length = [md5String length];
    newLine->chars  = malloc(newLine->length + 1);
    strncpy(newLine->chars, utf8String, newLine->length + 1);

    InsertLineAfter(newLine, iPlainLineListHead, &iPlainLineListHead);
}

#pragma mark -
//  entabLine:
// ----------------------------------------------------------------------------
//  A cheap and fast way to entab a line, assuming it contains no tabs already.
//  If tabs get added in the future, this WILL break. Single spaces are not
//  replaced with tabs, even when possible, since it would save no additional
//  bytes. Comments are not entabbed, as that would remove the user's ability
//  to search for them in the source code or a hex editor.

- (void)entabLine: (Line64*)ioLine;
{
    if (!ioLine || !ioLine->chars)
        return;

    // only need to do this math once...
    static uint32_t   startOfComment  = 0;

    if (startOfComment == 0)
    {
        startOfComment  = iFieldWidths.address + iFieldWidths.instruction +
            iFieldWidths.mnemonic + iFieldWidths.operands;

        if (iOpts.localOffsets)
            startOfComment  += iFieldWidths.offset;
    }

    char    entabbedLine[MAX_LINE_LENGTH];
    uint32_t  theOrigLength   = ioLine->length;

    // If 1st char is '\n', skip it.
    uint32_t  firstChar   = (ioLine->chars[0] == '\n');
    uint32_t  i;          // old line marker
    uint32_t  j   = 0;    // new line marker

    if (firstChar)
    {
        j++;
        entabbedLine[0] = '\n';
        entabbedLine[1] = 0;
    }
    else
        entabbedLine[0] = 0;

    // Inspect 4 bytes at a time.
    for (i = firstChar; i < theOrigLength; i += 4)
    {
        // Don't entab comments.
        if (i >= (startOfComment + firstChar) - 4)
        {
            strncpy(&entabbedLine[j], &ioLine->chars[i],
                (theOrigLength - i) + 1);

            break;
        }

        // If fewer than 4 bytes remain, adding any tabs is pointless.
        if (i > theOrigLength - 4)
        {   // Copy the remainder and split.
            while (i < theOrigLength)
                entabbedLine[j++] = ioLine->chars[i++];

            // Add the null terminator.
            entabbedLine[j] = 0;

            break;
        }

        // If the 4th char is not a space, the first 3 chars don't matter.
        if (ioLine->chars[i + 3] == 0x20)   // 4th char is a space...
        {
            if (ioLine->chars[i + 2] == 0x20)   // 3rd char is a space...
            {
                if (ioLine->chars[i + 1] == 0x20)   // 2nd char is a space...
                {
                    if (ioLine->chars[i] == 0x20)   // all 4 chars are spaces!
                        entabbedLine[j++] = '\t';   // write a tab and split
                    else    // only the 1st char is not a space
                    {       // copy 1st char and tab
                        entabbedLine[j++] = ioLine->chars[i];
                        entabbedLine[j++] = '\t';
                    }
                }
                else    // 2nd char is not a space
                {       // copy 1st 2 chars and tab
                    entabbedLine[j++] = ioLine->chars[i];
                    entabbedLine[j++] = ioLine->chars[i + 1];
                    entabbedLine[j++] = '\t';
                }
            }
            else    // 3rd char is not a space
            {       // copy 1st 3 chars and tab
                entabbedLine[j++] = ioLine->chars[i];
                entabbedLine[j++] = ioLine->chars[i + 1];
                entabbedLine[j++] = ioLine->chars[i + 2];
                entabbedLine[j++] = '\t';
            }
        }
        else    // 4th char is not a space
        {       // copy all 4 chars
            memcpy(&entabbedLine[j], &ioLine->chars[i], 4);
            j += 4;
        }

        // Add the null terminator.
        entabbedLine[j] = 0;
    }

    // Replace the old C string with the new one.
    free(ioLine->chars);
    ioLine->length  = strlen(entabbedLine);
    ioLine->chars   = malloc(ioLine->length + 1);
    strncpy(ioLine->chars, entabbedLine, ioLine->length + 1);
}

//  getPointer:type:    (was get_pointer)
// ----------------------------------------------------------------------------
//  Convert a relative ptr to an absolute ptr. Return which data type is being
//  referenced in outType.

- (char*)getPointer: (UInt64)inAddr
               type: (UInt8*)outType
{
    if (inAddr == 0)
        return NULL;

    if (outType)
        *outType = PointerType;

    char* thePtr = NULL;

            // (__TEXT,__cstring) (char*)
    if (inAddr >= iCStringSect.s.addr &&
        inAddr < iCStringSect.s.addr + iCStringSect.size)
    {
        thePtr = (iCStringSect.contents + (inAddr - iCStringSect.s.addr));

        // Make sure we're pointing to the beginning of a string,
        // not somewhere in the middle.
        if (*(thePtr - 1) != 0 && inAddr != iCStringSect.s.addr)
            thePtr  = NULL;
        // Check if this may be a Pascal string. Thanks, Metrowerks.
        else if (outType && strlen(thePtr) == thePtr[0] + 1)
            *outType    = PStringType;
    }
    else    // (__TEXT,__const) (Str255* sometimes)
    if (inAddr >= iConstTextSect.s.addr &&
        inAddr < iConstTextSect.s.addr + iConstTextSect.size)
    {
        thePtr  = (iConstTextSect.contents + (inAddr - iConstTextSect.s.addr));

        if (outType)
        {
            size_t length = strlen(thePtr);
            BOOL isPString = (length == (thePtr[0] + 1));
            if (isPString)
            {
                for (size_t i = 1; i <= length; i++)
                    isPString = isPString && (thePtr[i] >= 0x20 && thePtr[i] < 0x7F);
            }

            if (isPString)
                *outType = PStringType;
            else
                *outType = TextConstType;
        }
    }
    else    // (__TEXT,__literal4) (float)
    if (inAddr >= iLit4Sect.s.addr &&
        inAddr < iLit4Sect.s.addr + iLit4Sect.size)
    {
        thePtr  = (char*)(iLit4Sect.contents +
            (inAddr - iLit4Sect.s.addr));

        if (outType)
            *outType    = FloatType;
    }
    else    // (__TEXT,__literal8) (double)
    if (inAddr >= iLit8Sect.s.addr &&
        inAddr < iLit8Sect.s.addr + iLit8Sect.size)
    {
        thePtr  = (char*)(iLit8Sect.contents +
            (inAddr - iLit8Sect.s.addr));

        if (outType)
            *outType    = DoubleType;
    }

    if (thePtr)
        return thePtr;

            // (__IMPORT,__pointers) (cf_string_object*)
    if (inAddr >= iImpPtrSect.s.addr &&
        inAddr < iImpPtrSect.s.addr + iImpPtrSect.size)
    {
        thePtr  = (char*)(iImpPtrSect.contents +
            (inAddr - iImpPtrSect.s.addr));

        if (outType)
            *outType    = ImpPtrType;
    }

    if (thePtr)
        return thePtr;

            // (__DATA,__data) (char**)
    if (inAddr >= iDataSect.s.addr &&
        inAddr < iDataSect.s.addr + iDataSect.size)
    {
        thePtr = (char*)(iDataSect.contents + (inAddr - iDataSect.s.addr));

        UInt8 theType = DataGenericType;
        UInt64 theValue = *(UInt64*)thePtr;

        if (iSwapped)
            theValue = OSSwapInt64(theValue);

        if (theValue != 0)
        {
            theType = PointerType;

            static uint32_t recurseCount = 0;

            while (theType == PointerType)
            {
                recurseCount++;

                if (recurseCount > 5)
                {
                    theType = DataGenericType;
                    break;
                }

                thePtr = GetPointer(theValue, &theType);

                if (!thePtr)
                {
                    theType = DataGenericType;
                    break;
                }

                theValue = *(UInt64*)thePtr;
            }

            recurseCount = 0;
        }

        if (outType)
            *outType = theType;
    }
    else    // (__DATA,__const) (void*)
    if (inAddr >= iConstDataSect.s.addr &&
        inAddr < iConstDataSect.s.addr + iConstDataSect.size)
    {
        thePtr  = (char*)(iConstDataSect.contents +
            (inAddr - iConstDataSect.s.addr));

        if (outType)
        {
            uint32_t  theID   = *(uint32_t*)thePtr;

            if (iSwapped)
                theID   = OSSwapInt32(theID);

            if (theID == typeid_NSString)
                *outType    = OCStrObjectType;
            else
            {
                theID   = *(uint32_t*)(thePtr + 4);

                if (iSwapped)
                    theID   = OSSwapInt32(theID);

                if (theID == typeid_NSString)
                    *outType    = CFStringType;
                else
                    *outType    = DataConstType;
            }
        }
    }
/*    else    // (__DATA,__objc_classlist)
    if (inAddr >= iObjcClassListSect.s.addr &&
        inAddr < iObjcClassListSect.s.addr + iObjcClassListSect.size)
    {
    }*/
    else    // (__DATA,__objc_classrefs)
    if (inAddr >= iObjcClassRefsSect.s.addr &&
        inAddr < iObjcClassRefsSect.s.addr + iObjcClassRefsSect.size)
    {
        if (inAddr % 8 == 0)
        {
            UInt64 classRef = *(UInt64*)(iObjcClassRefsSect.contents +
                (inAddr - iObjcClassRefsSect.s.addr));

            if (classRef != 0)
            {
                if (iSwapped)
                    classRef = OSSwapInt64(classRef);

                objc2_class_t swappedClass = *(objc2_class_t*)(iObjcClassRefsSect.contents +
                    (classRef - iObjcClassRefsSect.s.addr));

                if (iSwapped)
                    swap_objc2_class(&swappedClass);

                objc2_class_ro_t roData = *(objc2_class_ro_t*)(iDataSect.contents +
                    (swappedClass.data - iDataSect.s.addr));

                if (iSwapped)
                    roData.name = OSSwapInt64(roData.name);

                thePtr = GetPointer(roData.name, NULL);

                if (outType)
                    *outType = OCClassRefType;
            }
        }
    }
    else    // (__DATA,__objc_msgrefs)
    if (inAddr >= iObjcMsgRefsSect.s.addr &&
        inAddr < iObjcMsgRefsSect.s.addr + iObjcMsgRefsSect.size)
    {
        objc2_message_ref_t ref = *(objc2_message_ref_t*)(iObjcMsgRefsSect.contents +
            (inAddr - iObjcMsgRefsSect.s.addr));

        if (iSwapped)
            ref.sel = OSSwapInt64(ref.sel);

        thePtr = GetPointer(ref.sel, NULL);

        if (outType)
            *outType = OCMsgRefType;
    }
    else    // (__DATA,__objc_catlist)
    if (inAddr >= iObjcCatListSect.s.addr &&
        inAddr < iObjcCatListSect.s.addr + iObjcCatListSect.size)
    {
    }
    else    // (__DATA,__objc_superrefs)
    if (inAddr >= iObjcSuperRefsSect.s.addr &&
        inAddr < iObjcSuperRefsSect.s.addr + iObjcSuperRefsSect.size)
    {
        UInt64 superAddy = *(UInt64*)(iObjcSuperRefsSect.contents +
            (inAddr - iObjcSuperRefsSect.s.addr));

        if (iSwapped)
            superAddy = OSSwapInt64(superAddy);

        if (superAddy != 0)
        {
            objc2_class_t swappedClass = *(objc2_class_t*)(iDataSect.contents +
                (superAddy - iDataSect.s.addr));

            if (iSwapped)
                swap_objc2_class(&swappedClass);

            if (swappedClass.data != 0)
            {
                objc2_class_ro_t* roPtr = (objc2_class_ro_t*)(iDataSect.contents +
                    (swappedClass.data - iDataSect.s.addr));
                UInt64 namePtr = roPtr->name;

                if (iSwapped)
                    namePtr = OSSwapInt64(namePtr);

                if (namePtr != 0)
                {
                    thePtr = GetPointer(namePtr, NULL);

                    if (outType)
                        *outType = OCSuperRefType;
                }
            }
        }
    }
    else    // (__DATA,__objc_selrefs)
    if (inAddr >= iObjcSelRefsSect.s.addr &&
        inAddr < iObjcSelRefsSect.s.addr + iObjcSelRefsSect.size)
    {
        UInt64 selAddy = *(UInt64*)(iObjcSelRefsSect.contents +
            (inAddr - iObjcSelRefsSect.s.addr));

        if (iSwapped)
            selAddy = OSSwapInt64(selAddy);

        if (selAddy != 0)
        {
            thePtr = GetPointer(selAddy, NULL);

            if (outType)
                *outType = OCSelRefType;
        }
    }
    else
    if ((inAddr >= iObjcProtoRefsSect.s.addr &&    // (__DATA,__objc_protorefs)
        inAddr < iObjcProtoRefsSect.s.addr + iObjcProtoRefsSect.size) ||
        (inAddr >= iObjcProtoListSect.s.addr &&    // (__DATA,__objc_protolist)
        inAddr < iObjcProtoListSect.s.addr + iObjcProtoListSect.size))
    {
        UInt64 protoAddy;
        UInt8 tempType;

        if (inAddr >= iObjcProtoRefsSect.s.addr &&
            inAddr < iObjcProtoRefsSect.s.addr + iObjcProtoRefsSect.size)
        {
            protoAddy = *(UInt64*)(iObjcProtoRefsSect.contents +
                (inAddr - iObjcProtoRefsSect.s.addr));
            tempType = OCProtoRefType;
        }
        else
        {
            protoAddy = *(UInt64*)(iObjcProtoListSect.contents +
                (inAddr - iObjcProtoListSect.s.addr));
            tempType = OCProtoListType;
        }

        if (iSwapped)
            protoAddy = OSSwapInt64(protoAddy);

        if (protoAddy != 0 &&
            (protoAddy >= iDataSect.s.addr && protoAddy < (iDataSect.s.addr + iDataSect.size)))
        {
            objc2_protocol_t* proto = (objc2_protocol_t*)(iDataSect.contents +
                (protoAddy - iDataSect.s.addr));
            UInt64 protoName = proto->name;

            if (iSwapped)
                protoName = OSSwapInt64(protoName);

            if (protoName != 0)
            {
                thePtr = GetPointer(protoName, NULL);

                if (outType)
                    *outType = tempType;
            }
        }
    }
    else    // (__DATA,__cfstring) (cf_string_object*)
    if (inAddr >= iCFStringSect.s.addr &&
        inAddr < iCFStringSect.s.addr + iCFStringSect.size)
    {
        thePtr  = (char*)(iCFStringSect.contents +
            (inAddr - iCFStringSect.s.addr));

        if (outType)
            *outType    = CFStringType;
    }
    else    // (__DATA,__nl_symbol_ptr) (cf_string_object*)
    if (inAddr >= iNLSymSect.s.addr &&
        inAddr < iNLSymSect.s.addr + iNLSymSect.size)
    {
        thePtr  = (char*)(iNLSymSect.contents +
            (inAddr - iNLSymSect.s.addr));

        if (outType)
            *outType    = NLSymType;
    }
    else    // (__DATA,__dyld) (function ptr)
    if (inAddr >= iDyldSect.s.addr &&
        inAddr < iDyldSect.s.addr + iDyldSect.size)
    {
        thePtr  = (char*)(iDyldSect.contents +
            (inAddr - iDyldSect.s.addr));

        if (outType)
            *outType    = DYLDType;
    }

    // should implement these if they ever contain CFStrings or NSStrings
/*  else    // (__DATA, __coalesced_data) (?)
    if (localAddy >= mCoalDataSect.s.addr &&
        localAddy < mCoalDataSect.s.addr + mCoalDataSect.size)
    {
    }
    else    // (__DATA, __datacoal_nt) (?)
    if (localAddy >= mCoalDataNTSect.s.addr &&
        localAddy < mCoalDataNTSect.s.addr + mCoalDataNTSect.size)
    {
    }*/

    return thePtr;
}

#pragma mark -
//  speedyDelivery
// ----------------------------------------------------------------------------

- (void)speedyDelivery
{
    [super speedyDelivery];

    LineIsCode                      = LineIsCode64FuncType
        [self methodForSelector: LineIsCodeSel];
    LineIsFunction                  = LineIsFunction64FuncType
        [self methodForSelector: LineIsFunctionSel];
    CodeIsBlockJump                 = CodeIsBlockJump64FuncType
        [self methodForSelector: CodeIsBlockJumpSel];
    AddressFromLine                 = AddressFromLine64FuncType
        [self methodForSelector: AddressFromLineSel];
    CodeFromLine                    = CodeFromLine64FuncType
        [self methodForSelector: CodeFromLineSel];
    CheckThunk                      = CheckThunk64FuncType
        [self methodForSelector : CheckThunkSel];
    ProcessLine                     = ProcessLine64FuncType
        [self methodForSelector: ProcessLineSel];
    ProcessCodeLine                 = ProcessCodeLine64FuncType
        [self methodForSelector: ProcessCodeLineSel];
    PostProcessCodeLine             = PostProcessCodeLine64FuncType
        [self methodForSelector: PostProcessCodeLineSel];
    ChooseLine                      = ChooseLine64FuncType
        [self methodForSelector: ChooseLineSel];
    EntabLine                       = EntabLine64FuncType
        [self methodForSelector: EntabLineSel];
    GetPointer                      = GetPointer64FuncType
        [self methodForSelector: GetPointerSel];
    CommentForLine                  = CommentForLine64FuncType
        [self methodForSelector: CommentForLineSel];
    CommentForSystemCall            = CommentForSystemCall64FuncType
        [self methodForSelector: CommentForSystemCallSel];
    CommentForMsgSendFromLine       = CommentForMsgSendFromLine64FuncType
        [self methodForSelector: CommentForMsgSendFromLineSel];
    SelectorForMsgSend              = SelectorForMsgSend64FuncType
        [self methodForSelector: SelectorForMsgSendSel];
    ResetRegisters                  = ResetRegisters64FuncType
        [self methodForSelector: ResetRegistersSel];
    UpdateRegisters                 = UpdateRegisters64FuncType
        [self methodForSelector: UpdateRegistersSel];
    RestoreRegisters                = RestoreRegisters64FuncType
        [self methodForSelector: RestoreRegistersSel];
    SendTypeFromMsgSend             = SendTypeFromMsgSend64FuncType
        [self methodForSelector: SendTypeFromMsgSendSel];
    PrepareNameForDemangling        = PrepareNameForDemangling64FuncType
        [self methodForSelector: PrepareNameForDemanglingSel];
    GetObjcClassPtrFromMethod       = GetObjcClassPtrFromMethod64FuncType
        [self methodForSelector: GetObjcClassPtrFromMethodSel];
    GetObjcMethodFromAddress        = GetObjcMethodFromAddress64FuncType
        [self methodForSelector: GetObjcMethodFromAddressSel];
    GetObjcClassFromName            = GetObjcClassFromName64FuncType
        [self methodForSelector: GetObjcClassFromNameSel];
    GetObjcClassPtrFromName         = GetObjcClassPtrFromName64FuncType
        [self methodForSelector: GetObjcClassPtrFromNameSel];
    GetObjcDescriptionFromObject    = GetObjcDescriptionFromObject64FuncType
        [self methodForSelector: GetObjcDescriptionFromObjectSel];
    GetObjcMetaClassFromClass       = GetObjcMetaClassFromClass64FuncType
        [self methodForSelector: GetObjcMetaClassFromClassSel];
    InsertLineBefore                = InsertLineBefore64FuncType
        [self methodForSelector: InsertLineBeforeSel];
    InsertLineAfter                 = InsertLineAfter64FuncType
        [self methodForSelector: InsertLineAfterSel];
    ReplaceLine                     = ReplaceLine64FuncType
        [self methodForSelector: ReplaceLineSel];
    DeleteLinesBefore               = DeleteLinesBefore64FuncType
        [self methodForSelector: DeleteLinesBeforeSel];
    FindSymbolByAddress             = FindSymbolByAddress64FuncType
        [self methodForSelector: FindSymbolByAddressSel];
    FindClassMethodByAddress        = FindClassMethodByAddress64FuncType
        [self methodForSelector: FindClassMethodByAddressSel];
    FindCatMethodByAddress          = FindCatMethodByAddress64FuncType
        [self methodForSelector: FindCatMethodByAddressSel];
    FindIvar                        = FindIvar64FuncType
        [self methodForSelector: FindIvarSel];
}

#ifdef OTX_DEBUG
//  printSymbol:
// ----------------------------------------------------------------------------
//  Used for symbol debugging.

- (void)printSymbol: (nlist_64)inSym
{
    fprintf(stderr, "----------------\n\n");
    fprintf(stderr, " n_strx = 0x%08x\n", inSym.n_un.n_strx);
    fprintf(stderr, " n_type = 0x%02x\n", inSym.n_type);
    fprintf(stderr, " n_sect = 0x%02x\n", inSym.n_sect);
    fprintf(stderr, " n_desc = 0x%04x\n", inSym.n_desc);
    fprintf(stderr, "n_value = 0x%016llx (%llu)\n\n", inSym.n_value, inSym.n_value);

    if ((inSym.n_type & N_STAB) != 0)
    {   // too complicated, see <mach-o/stab.h>
        fprintf(stderr, "STAB symbol\n");
    }
    else    // not a STAB
    {
        if ((inSym.n_type & N_PEXT) != 0)
            fprintf(stderr, "Private external symbol\n\n");
        else if ((inSym.n_type & N_EXT) != 0)
            fprintf(stderr, "External symbol\n\n");

        UInt8   theNType    = inSym.n_type & N_TYPE;
        UInt16  theRefType  = inSym.n_desc & REFERENCE_TYPE;

        fprintf(stderr, "Symbol name: %s\n", (char*)((uint32_t)iMachHeaderPtr + iStringTableOffset + inSym.n_un.n_strx));
        fprintf(stderr, "Symbol type: ");

        if (theNType == N_ABS)
            fprintf(stderr, "Absolute\n");
        else if (theNType == N_SECT)
            fprintf(stderr, "Defined in section %u\n", inSym.n_sect);
        else if (theNType == N_INDR)
            fprintf(stderr, "Indirect\n");
        else
        {
            if (theNType == N_UNDF)
                fprintf(stderr, "Undefined\n");
            else if (theNType == N_PBUD)
                fprintf(stderr, "Prebound undefined\n");

            switch (theRefType)
            {
                case REFERENCE_FLAG_UNDEFINED_NON_LAZY:
                    fprintf(stderr, "REFERENCE_FLAG_UNDEFINED_NON_LAZY\n");
                    break;
                case REFERENCE_FLAG_UNDEFINED_LAZY:
                    fprintf(stderr, "REFERENCE_FLAG_UNDEFINED_LAZY\n");
                    break;
                case REFERENCE_FLAG_DEFINED:
                    fprintf(stderr, "REFERENCE_FLAG_DEFINED\n");
                    break;
                case REFERENCE_FLAG_PRIVATE_DEFINED:
                    fprintf(stderr, "REFERENCE_FLAG_PRIVATE_DEFINED\n");
                    break;
                case REFERENCE_FLAG_PRIVATE_UNDEFINED_NON_LAZY:
                    fprintf(stderr, "REFERENCE_FLAG_PRIVATE_UNDEFINED_NON_LAZY\n");
                    break;
                case REFERENCE_FLAG_PRIVATE_UNDEFINED_LAZY:
                    fprintf(stderr, "REFERENCE_FLAG_PRIVATE_UNDEFINED_LAZY\n");
                    break;

                default:
                    break;
            }
        }
    }

    fprintf(stderr, "\n");
}

//  printBlocks:
// ----------------------------------------------------------------------------
//  Used for block debugging. Sublclasses may override.

- (void)printBlocks: (uint32_t)inFuncIndex;
{}
#endif  // OTX_DEBUG

@end
