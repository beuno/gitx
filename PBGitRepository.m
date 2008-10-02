//
//  PBGitRepository.m
//  GitTest
//
//  Created by Pieter de Bie on 13-06-08.
//  Copyright 2008 __MyCompanyName__. All rights reserved.
//

#import "PBGitRepository.h"
#import "PBGitCommit.h"
#import "PBGitWindowController.h"

#import "NSFileHandleExt.h"
#import "PBEasyPipe.h"
#import "PBGitRef.h"
#import "PBGitRevSpecifier.h"

NSString* PBGitRepositoryErrorDomain = @"GitXErrorDomain";

@implementation PBGitRepository

@synthesize revisionList, branches, currentBranch, refs, hasChanged;
static NSString* gitPath;

+ (void) initialize
{
	// Check what we might have in user defaults
	// NOTE: Currently this should NOT have a registered default, or the searching bits below won't work
	gitPath = [[NSUserDefaults standardUserDefaults] stringForKey:@"gitExecutable"];
	if (gitPath.length > 0)
		return;
	
	// Did not find a preference that told us where git is, try to find it in the filesystem instead
	gitPath = [self findGit];
	
	if(gitPath == nil)
	{
		NSLog(@"Could not find a git binary!");
	}
}

+ (NSString*) findGit
{
	// Try to find the path of the Git binary
	char* cpath = getenv("GIT_PATH");
	if (cpath != nil) {
		return [NSString stringWithCString:cpath];
	}
	
	NSString *path;
	// No explicit path. Try it with "which"
	path = [PBEasyPipe outputForCommand:@"/usr/bin/which" withArgs:[NSArray arrayWithObject:@"git"]];
	if (path.length > 0)
		return path;
	
	// Still no path. Let's try some default locations.
	NSArray* locations = [NSArray arrayWithObjects:@"/opt/local/bin/git",
						  @"/sw/bin/git",
						  @"/opt/git/bin/git",
						  @"/usr/local/bin/git",
						  nil];
	for (NSString* location in locations) {
		if ([[NSFileManager defaultManager] fileExistsAtPath:location]) {
			return location;
		}
	}
	
	return nil;
}

+ (BOOL) validateGit:(NSString *)path
{
	NSString *output = [PBEasyPipe outputForCommand:path withArgs:[NSArray arrayWithObject:@"--version"]];
	return [output hasPrefix:@"git version"];
}

- (BOOL)readFromData:(NSData *)data ofType:(NSString *)typeName error:(NSError **)outError
{
	if (outError) {
		*outError = [NSError errorWithDomain:PBGitRepositoryErrorDomain
                                      code:0
                                  userInfo:[NSDictionary dictionaryWithObject:@"Reading files is not supported." forKey:NSLocalizedFailureReasonErrorKey]];
	}
	return NO;
}

+ (BOOL) isBareRepository: (NSString*) path
{
	return [[PBEasyPipe outputForCommand:gitPath withArgs:[NSArray arrayWithObjects:@"rev-parse", @"--is-bare-repository", nil] inDir:path] isEqualToString:@"true"];
}

+ (NSURL*)gitDirForURL:(NSURL*)repositoryURL;
{
	NSString* repositoryPath = [repositoryURL path];

	if ([self isBareRepository:repositoryPath])
		return repositoryURL;


	// Use rev-parse to find the .git dir for the repository being opened
	NSString* newPath = [PBEasyPipe outputForCommand:gitPath withArgs:[NSArray arrayWithObjects:@"rev-parse", @"--git-dir", nil] inDir:repositoryPath];
	if ([newPath isEqualToString:@".git"])
		return [NSURL fileURLWithPath:[repositoryPath stringByAppendingPathComponent:@".git"]];
	if ([newPath length] > 0)
		return [NSURL fileURLWithPath:newPath];

	return nil;
}

// For a given path inside a repository, return either the .git dir
// (for a bare repo) or the directory above the .git dir otherwise
+ (NSURL*)baseDirForURL:(NSURL*)repositoryURL;
{
	NSURL* gitDirURL         = [self gitDirForURL:repositoryURL];
	NSString* repositoryPath = [gitDirURL path];

	if (![self isBareRepository:repositoryPath]) {
		repositoryURL = [NSURL fileURLWithPath:[[repositoryURL path] stringByDeletingLastPathComponent]];
	}

	return repositoryURL;
}

- (BOOL)readFromFileWrapper:(NSFileWrapper *)fileWrapper ofType:(NSString *)typeName error:(NSError **)outError
{
	BOOL success = NO;

	if (![fileWrapper isDirectory]) {
		if (outError) {
			NSDictionary* userInfo = [NSDictionary dictionaryWithObject:[NSString stringWithFormat:@"Reading files is not supported.", [fileWrapper filename]]
                                                              forKey:NSLocalizedRecoverySuggestionErrorKey];
			*outError = [NSError errorWithDomain:PBGitRepositoryErrorDomain code:0 userInfo:userInfo];
		}
	} else {
		NSURL* gitDirURL = [PBGitRepository gitDirForURL:[self fileURL]];
		if (gitDirURL) {
			[self setFileURL:gitDirURL];
			success = YES;
		} else if (outError) {
			NSDictionary* userInfo = [NSDictionary dictionaryWithObject:[NSString stringWithFormat:@"%@ does not appear to be a git repository.", [fileWrapper filename]]
                                                              forKey:NSLocalizedRecoverySuggestionErrorKey];
			*outError = [NSError errorWithDomain:PBGitRepositoryErrorDomain code:0 userInfo:userInfo];
		}

		if (success) {
			[self setup];
			[self readCurrentBranch];
		}
	}

	return success;
}

- (void) setup
{
	self.branches = [NSMutableArray array];
	[self reloadRefs];
	revisionList = [[PBGitRevList alloc] initWithRepository:self];
}

- (id) initWithURL: (NSURL*) path
{
	NSURL* gitDirURL = [PBGitRepository gitDirForURL:path];
	if (!gitDirURL)
		return nil;

	self = [self init];
	[self setFileURL: gitDirURL];

	[self setup];
	
	// We don't want the window controller to display anything yet..
	// We'll leave that to the caller of this method.
	[self addWindowController:[[PBGitWindowController alloc] initWithRepository:self displayDefault:NO]];
	[self showWindows];

	return self;
}

// The fileURL the document keeps is to the .git dir, but that’s pretty
// useless for display in the window title bar, so we show the directory above
- (NSString*)displayName
{
	NSString* displayName = self.fileURL.path.lastPathComponent;
	if ([displayName isEqualToString:@".git"])
		displayName = [self.fileURL.path stringByDeletingLastPathComponent].lastPathComponent;
	return displayName;
}

// Overridden to create our custom window controller
- (void)makeWindowControllers
{
	[self addWindowController: [[PBGitWindowController alloc] initWithRepository:self displayDefault:YES]];
}

- (NSWindowController *)windowController
{
	if ([[self windowControllers] count] == 0)
		return NULL;
	
	return [[self windowControllers] objectAtIndex:0];
}

- (void) addRef: (PBGitRef *) ref fromParameters: (NSArray *) components
{
	NSString* type = [components objectAtIndex:1];

	NSString* sha;
	if ([type isEqualToString:@"tag"] && [components count] == 4)
		sha = [components objectAtIndex:3];
	else
		sha = [components objectAtIndex:2];

	NSMutableArray* curRefs;
	if (curRefs = [refs objectForKey:sha])
		[curRefs addObject:ref];
	else
		[refs setObject:[NSMutableArray arrayWithObject:ref] forKey:sha];
}

// reloadRefs: reload all refs in the repository, like in readRefs
// To stay compatible, this does not remove a ref from the branches list
// even after it has been deleted.
// returns YES when a ref was changed
- (BOOL) reloadRefs
{
	BOOL ret = NO;

	refs = [NSMutableDictionary dictionary];

	NSString* output = [PBEasyPipe outputForCommand:gitPath 
										   withArgs:[NSArray arrayWithObjects:@"for-each-ref", @"--format=%(refname) %(objecttype) %(objectname)"
													 " %(*objectname)", @"refs", nil]
											  inDir: self.fileURL.path];
	NSArray* lines = [output componentsSeparatedByString:@"\n"];

	for (NSString* line in lines) {
		NSArray* components = [line componentsSeparatedByString:@" "];

		// First do the ref matching. If this ref is new, add it to our ref list
		PBGitRef *newRef = [PBGitRef refFromString:[components objectAtIndex:0]];
		PBGitRevSpecifier* revSpec = [[PBGitRevSpecifier alloc] initWithRef:newRef];
		if ([[newRef type] isEqualToString:@"head"] || [[newRef type] isEqualToString:@"remote"])
			if ([self addBranch:revSpec] != revSpec)
				ret = YES;

		// Also add this ref to the refs list
		[self addRef:newRef fromParameters:components];
	}

	self.refs = refs;
	return ret;
}

- (void) lazyReload
{
	if (!hasChanged)
		return;

	[self reloadRefs];
	[self.revisionList reload];
	hasChanged = NO;
}

- (PBGitRevSpecifier*) headRef
{
	NSString* branch = [self parseSymbolicReference: @"HEAD"];
	if (branch && [branch hasPrefix:@"refs/heads/"])
		return [[PBGitRevSpecifier alloc] initWithRef:[PBGitRef refFromString:branch]];

	return [[PBGitRevSpecifier alloc] initWithRef:[PBGitRef refFromString:@"HEAD"]];
}
		
// Returns either this object, or an existing, equal object
- (PBGitRevSpecifier*) addBranch: (PBGitRevSpecifier*) rev
{
	if ([[rev parameters] count] == 0)
		rev = [self headRef];

	// First check if the branch doesn't exist already
	for (PBGitRevSpecifier* r in branches)
		if ([rev isEqualTo: r])
			return r;

	[self willChangeValueForKey:@"branches"];
	[branches addObject: rev];
	[self didChangeValueForKey:@"branches"];
	return rev;
}

- (void) showHistoryView
{
	if (!self.windowController)
		return;
	
	[((PBGitWindowController *)self.windowController) showHistoryView:self];
}

- (void) selectBranch: (PBGitRevSpecifier*) rev
{
	int i;
	for (i = 0; i < [branches count]; i++) {
		PBGitRevSpecifier* aRev = [branches objectAtIndex:i];
		if (rev == aRev) {
			self.currentBranch = [NSIndexSet indexSetWithIndex:i];
			[self showHistoryView];
			return;
		}
	}
}
	
- (void) readCurrentBranch
{
		[self selectBranch: [self addBranch: [self headRef]]];
}

- (NSString *) workingDirectory
{
	if ([self.fileURL.path hasSuffix:@"/.git"])
		return [self.fileURL.path substringToIndex:[self.fileURL.path length] - 5];
	else if ([[self outputForCommand:@"rev-parse --is-inside-work-tree"] isEqualToString:@"true"])
		return gitPath;
	
	return nil;
}		

- (int) returnValueForCommand:(NSString *)cmd
{
	int i;
	[self outputForCommand:cmd retValue: &i];
	return i;
}

- (NSFileHandle*) handleForArguments:(NSArray *)args
{
	NSString* gitDirArg = [@"--git-dir=" stringByAppendingString:self.fileURL.path];
	NSMutableArray* arguments =  [NSMutableArray arrayWithObject: gitDirArg];
	[arguments addObjectsFromArray: args];
	return [PBEasyPipe handleForCommand:gitPath withArgs:arguments];
}

- (NSFileHandle*) handleInWorkDirForArguments:(NSArray *)args
{
	NSString* gitDirArg = [@"--git-dir=" stringByAppendingString:self.fileURL.path];
	NSMutableArray* arguments =  [NSMutableArray arrayWithObject: gitDirArg];
	[arguments addObjectsFromArray: args];
	return [PBEasyPipe handleForCommand:gitPath withArgs:arguments inDir:[self workingDirectory]];
}

- (NSFileHandle*) handleForCommand:(NSString *)cmd
{
	NSArray* arguments = [cmd componentsSeparatedByString:@" "];
	return [self handleForArguments:arguments];
}

- (NSString*) outputForCommand:(NSString *)cmd
{
	NSArray* arguments = [cmd componentsSeparatedByString:@" "];
	return [self outputForArguments: arguments];
}

- (NSString*) outputForCommand:(NSString *)str retValue:(int *)ret;
{
	NSArray* arguments = [str componentsSeparatedByString:@" "];
	return [self outputForArguments: arguments retValue: ret];
}

- (NSString*) outputForArguments:(NSArray*) arguments
{
	return [PBEasyPipe outputForCommand:gitPath withArgs:arguments inDir: self.fileURL.path];
}

- (NSString*) outputInWorkdirForArguments:(NSArray*) arguments
{
	return [PBEasyPipe outputForCommand:gitPath withArgs:arguments inDir: [self workingDirectory]];
}


- (NSString*) outputForArguments:(NSArray *)arguments retValue:(int *)ret;
{
	return [PBEasyPipe outputForCommand:gitPath withArgs:arguments inDir: self.fileURL.path retValue: ret];
}

- (NSString*) outputForArguments:(NSArray *)arguments inputString:(NSString *)input retValue:(int *)ret;
{
	return [PBEasyPipe outputForCommand:gitPath
							   withArgs:arguments
								  inDir: self.fileURL.path
							inputString:input
							   retValue: ret];
}

- (NSString*) parseReference:(NSString *)reference
{
	return [self outputForArguments:[NSArray arrayWithObjects: @"rev-parse", reference, nil]];
}

- (NSString*) parseSymbolicReference:(NSString*) reference
{
	NSString* ref = [self outputForArguments:[NSArray arrayWithObjects: @"symbolic-ref", reference, nil]];
	if ([ref hasPrefix:@"refs/"])
		return ref;

	return nil;
}

- (BOOL) removeRef:(NSString *)ref
{
	int i;
	[self outputForArguments:[NSArray arrayWithObjects:@"branch", @"-D", ref, nil] retValue:&i];
	
	if (i == 0) {
		// Todo: We can do better than this!
		[self reloadRefs];
		[revisionList reload];
		return YES;
	}
	return NO;
}
@end
