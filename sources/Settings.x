#import "Settings.h"
#import "Util.h"

static void Toast(UIViewController *viewController, NSString *message) {
    if (!viewController || message.length == 0)
        return;
    Class toastClass = NSClassFromString(@"YTToastResponderEvent");
    if ([toastClass respondsToSelector:@selector(eventWithMessage:firstResponder:)])
        [[toastClass eventWithMessage:message firstResponder:viewController] send];
}

static YTSettingsViewController *SettingsViewControllerForManager(YTSettingsSectionItemManager *manager) {
    if (!manager)
        return nil;

    @try {
        id delegate = [manager valueForKey:@"_dataDelegate"];
        if ([delegate isKindOfClass:%c(YTSettingsViewController)])
            return delegate;
        delegate = [manager valueForKey:@"_settingsViewControllerDelegate"];
        if ([delegate isKindOfClass:%c(YTSettingsViewController)])
            return delegate;
    } @catch (__unused NSException *exception) {
    }
    return nil;
}

@interface ListEntry : NSObject
@property(nonatomic, copy) NSString *title;
@property(nonatomic, copy) NSString *subtitle;
@property(nonatomic, copy) dispatch_block_t action;
+ (instancetype)entryWithTitle:(NSString *)title subtitle:(NSString *)subtitle action:(dispatch_block_t)action;
@end

@implementation ListEntry

+ (instancetype)entryWithTitle:(NSString *)title subtitle:(NSString *)subtitle action:(dispatch_block_t)action {
    ListEntry *entry = [self new];
    entry.title = title ?: @"";
    entry.subtitle = subtitle;
    entry.action = action;
    return entry;
}

@end

@interface ListViewController : UITableViewController <UISearchResultsUpdating>
@property(nonatomic, copy) NSArray<ListEntry *> *(^entriesProvider)(void);
@property(nonatomic, copy) NSString *searchPlaceholder;
@property(nonatomic, copy) NSArray<ListEntry *> *entries;
@property(nonatomic, copy) NSArray<ListEntry *> *filteredEntries;
- (instancetype)initWithTitle:(NSString *)title
             searchPlaceholder:(NSString *)searchPlaceholder
              entriesProvider:(NSArray<ListEntry *> *(^)(void))entriesProvider;
- (void)refreshEntries;
@end

@implementation ListViewController

- (instancetype)initWithTitle:(NSString *)title
             searchPlaceholder:(NSString *)searchPlaceholder
              entriesProvider:(NSArray<ListEntry *> *(^)(void))entriesProvider {
    self = [super initWithStyle:UITableViewStyleInsetGrouped];
    if (self) {
        self.title = title;
        _searchPlaceholder = [searchPlaceholder copy];
        _entriesProvider = [entriesProvider copy];
        _entries = @[];
        _filteredEntries = @[];
    }
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.tableView.keyboardDismissMode = UIScrollViewKeyboardDismissModeOnDrag;
    self.tableView.rowHeight = UITableViewAutomaticDimension;
    self.tableView.estimatedRowHeight = 56.0;

    UISearchController *searchController = [[UISearchController alloc] initWithSearchResultsController:nil];
    searchController.searchResultsUpdater = self;
    searchController.obscuresBackgroundDuringPresentation = NO;
    searchController.searchBar.placeholder = self.searchPlaceholder;
    self.navigationItem.searchController = searchController;
    self.navigationItem.hidesSearchBarWhenScrolling = NO;
    self.definesPresentationContext = YES;
    [self refreshEntries];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self refreshEntries];
}

- (void)refreshEntries {
    self.entries = self.entriesProvider ? self.entriesProvider() : @[];
    NSString *query = self.navigationItem.searchController.searchBar.text;
    if (query.length == 0) {
        self.filteredEntries = self.entries;
    } else {
        NSString *normalizedQuery = query.lowercaseString;
        self.filteredEntries = [self.entries filteredArrayUsingPredicate:
            [NSPredicate predicateWithBlock:^BOOL(ListEntry *entry, NSDictionary *bindings) {
                return [entry.title.lowercaseString containsString:normalizedQuery] ||
                       [entry.subtitle.lowercaseString containsString:normalizedQuery];
            }]];
    }
    [self.tableView reloadData];
}

- (void)updateSearchResultsForSearchController:(UISearchController *)searchController {
    [self refreshEntries];
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return self.filteredEntries.count;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    static NSString *cellIdentifier = @"GonerinoListCell";
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:cellIdentifier];
    if (!cell)
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:cellIdentifier];

    ListEntry *entry = self.filteredEntries[indexPath.row];
    cell.textLabel.text = entry.title;
    cell.detailTextLabel.text = entry.subtitle;
    cell.accessoryType = entry.action ? UITableViewCellAccessoryDisclosureIndicator : UITableViewCellAccessoryNone;
    cell.selectionStyle = entry.action ? UITableViewCellSelectionStyleDefault : UITableViewCellSelectionStyleNone;
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    ListEntry *entry = self.filteredEntries[indexPath.row];
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    if (entry.action)
        entry.action();
}

@end

@interface SettingsViewController : UITableViewController <UIDocumentPickerDelegate>
@property(nonatomic, weak) YTSettingsSectionItemManager *settingsManager;
@property(nonatomic, assign) BOOL importingSettings;
- (instancetype)initWithSettingsManager:(YTSettingsSectionItemManager *)settingsManager;
@end

@implementation SettingsViewController

- (instancetype)initWithSettingsManager:(YTSettingsSectionItemManager *)settingsManager {
    self = [super initWithStyle:UITableViewStyleInsetGrouped];
    if (self) {
        self.title = @"Gonerino";
        _settingsManager = settingsManager;
    }
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.tableView.rowHeight = UITableViewAutomaticDimension;
    self.tableView.estimatedRowHeight = 56.0;
    self.navigationItem.largeTitleDisplayMode = UINavigationItemLargeTitleDisplayModeNever;
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self.tableView reloadData];
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    return 4;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    switch (section) {
        case 0:
            return 4;
        case 1:
            return 3;
        case 2:
            return 2;
        default:
            return 3;
    }
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    switch (section) {
        case 0:
            return @"Filtering";
        case 1:
            return @"Blocked Content";
        case 2:
            return @"Settings";
        default:
            return @"About";
    }
}

- (NSString *)titleForRow:(NSIndexPath *)indexPath {
    if (indexPath.section == 0)
        return @[@"Enable Gonerino", @"Show Gonerino Button", @"Block 'People also watched'", @"Block 'You might also like'"][indexPath.row];
    if (indexPath.section == 1)
        return @[@"Channels", @"Videos", @"Words"][indexPath.row];
    if (indexPath.section == 2)
        return @[@"Export Settings", @"Import Settings"][indexPath.row];
    return @[@"GitHub", @"Donate", @"Version"][indexPath.row];
}

- (NSString *)subtitleForRow:(NSIndexPath *)indexPath {
    if (indexPath.section == 0) {
        return @[@"Remove blocked content from YouTube feeds",
                 @"Display the quick toggle in the top navigation bar",
                 @"Remove this recommendation section",
                 @"Remove this recommendation section"][indexPath.row];
    }
    if (indexPath.section == 1) {
        if (indexPath.row == 0)
            return [NSString stringWithFormat:@"%lu blocked channel%@", (unsigned long)[[ChannelManager sharedInstance] blockedChannels].count,
                                              [[ChannelManager sharedInstance] blockedChannels].count == 1 ? @"" : @"s"];
        if (indexPath.row == 1)
            return [NSString stringWithFormat:@"%lu blocked video%@", (unsigned long)[[VideoManager sharedInstance] blockedVideos].count,
                                              [[VideoManager sharedInstance] blockedVideos].count == 1 ? @"" : @"s"];
        return [NSString stringWithFormat:@"%lu blocked word%@", (unsigned long)[[WordManager sharedInstance] blockedWords].count,
                                          [[WordManager sharedInstance] blockedWords].count == 1 ? @"" : @"s"];
    }
    if (indexPath.section == 2)
        return indexPath.row == 0 ? @"Save your block lists and preferences" : @"Restore your block lists and preferences";
    if (indexPath.row == 0)
        return @"View source code and report issues";
    if (indexPath.row == 1)
        return @"Support Gonerino development";
    return [NSString stringWithFormat:@"v%@", TWEAK_VERSION];
}

- (BOOL)valueForSwitchRow:(NSInteger)row {
    switch (row) {
        case 0:
            return [[NSUserDefaults standardUserDefaults] objectForKey:@"GonerinoEnabled"] == nil
                       ? YES
                       : [[NSUserDefaults standardUserDefaults] boolForKey:@"GonerinoEnabled"];
        case 1:
            return [[NSUserDefaults standardUserDefaults] objectForKey:@"GonerinoShowButton"] == nil
                       ? YES
                       : [[NSUserDefaults standardUserDefaults] boolForKey:@"GonerinoShowButton"];
        case 2:
            return [[NSUserDefaults standardUserDefaults] boolForKey:@"GonerinoPeopleWatched"];
        default:
            return [[NSUserDefaults standardUserDefaults] boolForKey:@"GonerinoMightLike"];
    }
}

- (void)switchChanged:(UISwitch *)sender {
    NSArray *keys = @[@"GonerinoEnabled", @"GonerinoShowButton", @"GonerinoPeopleWatched", @"GonerinoMightLike"];
    [[NSUserDefaults standardUserDefaults] setBool:sender.isOn forKey:keys[sender.tag]];
    [[NSUserDefaults standardUserDefaults] synchronize];
    [Util refreshFeedViews];
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    NSString *identifier = indexPath.section == 0 ? @"GonerinoSwitchCell" : @"GonerinoActionCell";
    UITableViewCellStyle style = indexPath.section == 0 ? UITableViewCellStyleDefault : UITableViewCellStyleSubtitle;
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:identifier];
    if (!cell)
        cell = [[UITableViewCell alloc] initWithStyle:style reuseIdentifier:identifier];

    cell.textLabel.text = [self titleForRow:indexPath];
    cell.detailTextLabel.text = indexPath.section == 0 ? nil : [self subtitleForRow:indexPath];
    if (indexPath.section == 0) {
        UISwitch *control = [UISwitch new];
        control.tag = indexPath.row;
        control.on = [self valueForSwitchRow:indexPath.row];
        [control addTarget:self action:@selector(switchChanged:) forControlEvents:UIControlEventValueChanged];
        cell.accessoryView = control;
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
    } else {
        cell.accessoryView = nil;
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
        cell.selectionStyle = UITableViewCellSelectionStyleDefault;
    }
    return cell;
}

- (void)openChannels {
    __weak __block ListViewController *weakList;
    __weak typeof(self) weakSelf = self;
    ListViewController *list = [[ListViewController alloc]
           initWithTitle:@"Blocked Channels"
        searchPlaceholder:@"Search channels"
         entriesProvider:^NSArray<ListEntry *> *{
             NSMutableArray *entries = [NSMutableArray array];
             [entries addObject:[ListEntry entryWithTitle:@"Add Channel"
                                                           subtitle:@"Block a new channel"
                                                             action:^{
                                                                 UIAlertController *alert =
                                                                     [UIAlertController alertControllerWithTitle:@"Add Channel"
                                                                                                          message:@"Enter the channel name to block"
                                                                                                   preferredStyle:UIAlertControllerStyleAlert];
                                                                 [alert addTextFieldWithConfigurationHandler:^(UITextField *textField) {
                                                                     textField.placeholder = @"Channel Name";
                                                                 }];
                                                                 [alert addAction:[UIAlertAction actionWithTitle:@"Add"
                                                                                                           style:UIAlertActionStyleDefault
                                                                                                         handler:^(__unused UIAlertAction *action) {
                                                                                                             NSString *channel = alert.textFields.firstObject.text;
                                                                                                             if (channel.length == 0)
                                                                                                                 return;
                                                                                                             [[ChannelManager sharedInstance] addBlockedChannel:channel];
                                                                                                             [weakList refreshEntries];
                                                                                                             [weakSelf.settingsManager reloadSection];
                                                                                                         }]];
                                                                 [alert addAction:[UIAlertAction actionWithTitle:@"Cancel"
                                                                                                           style:UIAlertActionStyleCancel
                                                                                                         handler:nil]];
                                                                 [weakSelf presentViewController:alert animated:YES completion:nil];
                                                             }]];
             for (NSString *channel in [[ChannelManager sharedInstance] blockedChannels]) {
                 [entries addObject:[ListEntry entryWithTitle:channel
                                                               subtitle:nil
                                                                 action:^{
                                                                     UIAlertController *alert =
                                                                         [UIAlertController alertControllerWithTitle:@"Delete Channel"
                                                                                                              message:[NSString stringWithFormat:@"Are you sure you want to delete '%@'?", channel]
                                                                                                       preferredStyle:UIAlertControllerStyleAlert];
                                                                     [alert addAction:[UIAlertAction actionWithTitle:@"Delete"
                                                                                                               style:UIAlertActionStyleDestructive
                                                                                                             handler:^(__unused UIAlertAction *action) {
                                                                                                                 [[ChannelManager sharedInstance] removeBlockedChannel:channel];
                                                                                                                 [weakList refreshEntries];
                                                                                                                 [weakSelf.settingsManager reloadSection];
                                                                                                             }]];
                                                                     [alert addAction:[UIAlertAction actionWithTitle:@"Cancel"
                                                                                                               style:UIAlertActionStyleCancel
                                                                                                             handler:nil]];
                                                                     [weakSelf presentViewController:alert animated:YES completion:nil];
                                                                 }]];
             }
             return entries;
         }];
    weakList = list;
    [self.navigationController pushViewController:list animated:YES];
}

- (void)openVideos {
    __weak __block ListViewController *weakList;
    __weak typeof(self) weakSelf = self;
    ListViewController *list = [[ListViewController alloc]
           initWithTitle:@"Blocked Videos"
        searchPlaceholder:@"Search videos"
         entriesProvider:^NSArray<ListEntry *> *{
             NSMutableArray *entries = [NSMutableArray array];
             NSArray *videos = [[VideoManager sharedInstance] blockedVideos];
             if (videos.count == 0) {
                 [entries addObject:[ListEntry entryWithTitle:@"No blocked videos" subtitle:nil action:nil]];
                 return entries;
             }
             for (NSDictionary *video in videos) {
                 NSString *videoId = video[@"id"];
                 NSString *title = [(NSString *)video[@"title"] length] > 0 ? video[@"title"] : videoId;
                 NSString *channel = [(NSString *)video[@"channel"] length] > 0 ? video[@"channel"] : @"Unknown Channel";
                 [entries addObject:[ListEntry entryWithTitle:title
                                                               subtitle:channel
                                                                 action:^{
                                                                     UIAlertController *alert =
                                                                         [UIAlertController alertControllerWithTitle:@"Delete Video"
                                                                                                              message:[NSString stringWithFormat:@"Are you sure you want to delete '%@'?", title]
                                                                                                       preferredStyle:UIAlertControllerStyleAlert];
                                                                     [alert addAction:[UIAlertAction actionWithTitle:@"Delete"
                                                                                                               style:UIAlertActionStyleDestructive
                                                                                                             handler:^(__unused UIAlertAction *action) {
                                                                                                                 [[VideoManager sharedInstance] removeBlockedVideo:videoId];
                                                                                                                 [weakList refreshEntries];
                                                                                                                 [weakSelf.settingsManager reloadSection];
                                                                                                             }]];
                                                                     [alert addAction:[UIAlertAction actionWithTitle:@"Cancel"
                                                                                                               style:UIAlertActionStyleCancel
                                                                                                             handler:nil]];
                                                                     [weakSelf presentViewController:alert animated:YES completion:nil];
                                                                 }]];
             }
             return entries;
         }];
    weakList = list;
    [self.navigationController pushViewController:list animated:YES];
}

- (void)openWords {
    __weak __block ListViewController *weakList;
    __weak typeof(self) weakSelf = self;
    ListViewController *list = [[ListViewController alloc]
           initWithTitle:@"Blocked Words"
        searchPlaceholder:@"Search words"
         entriesProvider:^NSArray<ListEntry *> *{
             NSMutableArray *entries = [NSMutableArray array];
             [entries addObject:[ListEntry entryWithTitle:@"Add Word"
                                                           subtitle:@"Block a new word or phrase"
                                                             action:^{
                                                                 UIAlertController *alert =
                                                                     [UIAlertController alertControllerWithTitle:@"Add Word"
                                                                                                          message:@"Enter a word or phrase to block"
                                                                                                   preferredStyle:UIAlertControllerStyleAlert];
                                                                 [alert addTextFieldWithConfigurationHandler:^(UITextField *textField) {
                                                                     textField.placeholder = @"Word or phrase";
                                                                 }];
                                                                 [alert addAction:[UIAlertAction actionWithTitle:@"Add"
                                                                                                           style:UIAlertActionStyleDefault
                                                                                                         handler:^(__unused UIAlertAction *action) {
                                                                                                             NSString *word = alert.textFields.firstObject.text;
                                                                                                             if (word.length == 0)
                                                                                                                 return;
                                                                                                             [[WordManager sharedInstance] addBlockedWord:word];
                                                                                                             [weakList refreshEntries];
                                                                                                             [weakSelf.settingsManager reloadSection];
                                                                                                         }]];
                                                                 [alert addAction:[UIAlertAction actionWithTitle:@"Cancel"
                                                                                                           style:UIAlertActionStyleCancel
                                                                                                         handler:nil]];
                                                                 [weakSelf presentViewController:alert animated:YES completion:nil];
                                                             }]];
             for (NSString *word in [[WordManager sharedInstance] blockedWords]) {
                 [entries addObject:[ListEntry entryWithTitle:word
                                                               subtitle:nil
                                                                 action:^{
                                                                     UIAlertController *alert =
                                                                         [UIAlertController alertControllerWithTitle:@"Delete Word"
                                                                                                              message:[NSString stringWithFormat:@"Are you sure you want to delete '%@'?", word]
                                                                                                       preferredStyle:UIAlertControllerStyleAlert];
                                                                     [alert addAction:[UIAlertAction actionWithTitle:@"Delete"
                                                                                                               style:UIAlertActionStyleDestructive
                                                                                                             handler:^(__unused UIAlertAction *action) {
                                                                                                                 [[WordManager sharedInstance] removeBlockedWord:word];
                                                                                                                 [weakList refreshEntries];
                                                                                                                 [weakSelf.settingsManager reloadSection];
                                                                                                             }]];
                                                                     [alert addAction:[UIAlertAction actionWithTitle:@"Cancel"
                                                                                                               style:UIAlertActionStyleCancel
                                                                                                             handler:nil]];
                                                                     [weakSelf presentViewController:alert animated:YES completion:nil];
                                                                 }]];
             }
             return entries;
         }];
    weakList = list;
    [self.navigationController pushViewController:list animated:YES];
}

- (NSDictionary *)settingsDictionary {
    return @{
        @"blockedChannels": [[ChannelManager sharedInstance] blockedChannels],
        @"blockedVideos": [[VideoManager sharedInstance] blockedVideos],
        @"blockedWords": [[WordManager sharedInstance] blockedWords],
        @"gonerinoEnabled": @([[NSUserDefaults standardUserDefaults] objectForKey:@"GonerinoEnabled"] == nil
                                  ? YES
                                  : [[NSUserDefaults standardUserDefaults] boolForKey:@"GonerinoEnabled"]),
        @"showButton": @([[NSUserDefaults standardUserDefaults] objectForKey:@"GonerinoShowButton"] == nil
                             ? YES
                             : [[NSUserDefaults standardUserDefaults] boolForKey:@"GonerinoShowButton"]),
        @"blockPeopleWatched": @([[NSUserDefaults standardUserDefaults] boolForKey:@"GonerinoPeopleWatched"]),
        @"blockMightLike": @([[NSUserDefaults standardUserDefaults] boolForKey:@"GonerinoMightLike"])
    };
}

- (void)exportSettings {
    NSURL *fileURL = [NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:@"gonerino_settings.plist"]];
    [[self settingsDictionary] writeToURL:fileURL atomically:YES];
    self.importingSettings = NO;
    UIDocumentPickerViewController *picker = [[UIDocumentPickerViewController alloc] initForExportingURLs:@[fileURL]];
    picker.delegate = self;
    [self presentViewController:picker animated:YES completion:nil];
}

- (void)importSettings {
    self.importingSettings = YES;
    UIDocumentPickerViewController *picker = [[UIDocumentPickerViewController alloc]
        initForOpeningContentTypes:@[[UTType typeWithIdentifier:@"com.apple.property-list"]]];
    picker.delegate = self;
    [self presentViewController:picker animated:YES completion:nil];
}

- (void)applyImportedSettings:(NSDictionary *)settings {
    if ([settings[@"blockedChannels"] isKindOfClass:[NSArray class]])
        [[ChannelManager sharedInstance] setBlockedChannels:settings[@"blockedChannels"]];
    if ([settings[@"blockedWords"] isKindOfClass:[NSArray class]])
        [[WordManager sharedInstance] setBlockedWords:settings[@"blockedWords"]];
    if ([settings[@"blockedVideos"] isKindOfClass:[NSArray class]])
        [[VideoManager sharedInstance] setBlockedVideos:settings[@"blockedVideos"]];

    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    NSDictionary *defaultKeys = @{
        @"gonerinoEnabled": @"GonerinoEnabled",
        @"showButton": @"GonerinoShowButton",
        @"blockPeopleWatched": @"GonerinoPeopleWatched",
        @"blockMightLike": @"GonerinoMightLike"
    };
    for (NSString *settingsKey in defaultKeys) {
        if ([settings[settingsKey] isKindOfClass:[NSNumber class]])
            [defaults setBool:[settings[settingsKey] boolValue] forKey:defaultKeys[settingsKey]];
    }
    [defaults synchronize];
    [self.tableView reloadData];
    [self.settingsManager reloadSection];
    [Util refreshFeedViews];
}

- (void)documentPicker:(UIDocumentPickerViewController *)controller didPickDocumentsAtURLs:(NSArray<NSURL *> *)urls {
    if (!self.importingSettings) {
        Toast(self, @"Settings exported successfully");
        return;
    }
    NSURL *url = urls.firstObject;
    if (!url)
        return;
    [url startAccessingSecurityScopedResource];
    NSData *data = [NSData dataWithContentsOfURL:url options:0 error:nil];
    [url stopAccessingSecurityScopedResource];
    NSDictionary *settings = data ? [NSPropertyListSerialization propertyListWithData:data
                                                                                  options:NSPropertyListImmutable
                                                                                   format:NULL
                                                                                    error:nil]
                                  : nil;
    if (![settings isKindOfClass:[NSDictionary class]]) {
        Toast(self, @"Invalid settings file format");
        return;
    }
    [self applyImportedSettings:settings];
    Toast(self, @"Settings imported successfully");
}

- (void)documentPickerWasCancelled:(UIDocumentPickerViewController *)controller {
    Toast(self, self.importingSettings ? @"Import cancelled" : @"Export cancelled");
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    if (indexPath.section == 1) {
        if (indexPath.row == 0)
            [self openChannels];
        else if (indexPath.row == 1)
            [self openVideos];
        else
            [self openWords];
        return;
    }
    if (indexPath.section == 2) {
        if (indexPath.row == 0)
            [self exportSettings];
        else
            [self importSettings];
        return;
    }
    if (indexPath.section == 3) {
        NSArray *urls = @[
            @"https://github.com/castdrian/Gonerino",
            @"https://ko-fi.com/castdrian",
            @"https://github.com/castdrian/Gonerino/releases"
        ];
        [[UIApplication sharedApplication] openURL:[NSURL URLWithString:urls[indexPath.row]] options:@{} completionHandler:nil];
    }
}

@end

%hook YTAppSettingsPresentationData

+ (NSArray *)settingsCategoryOrder {
    NSArray *order = %orig;
    if ([order containsObject:@(Section)])
        return order;

    NSMutableArray *mutableOrder = [order mutableCopy];
    NSUInteger insertIndex = [order indexOfObject:@(1)];
    if (insertIndex == NSNotFound)
        [mutableOrder addObject:@(Section)];
    else
        [mutableOrder insertObject:@(Section) atIndex:insertIndex + 1];
    return mutableOrder;
}

%end

%hook YTSettingsSectionItemManager

%new
- (void)updateSectionWithEntry:(id)entry {
    YTSettingsViewController *settingsViewController = SettingsViewControllerForManager(self);
    if (!settingsViewController)
        return;
    NSMutableArray *sectionItems = [NSMutableArray array];
    SECTION_HEADER(@"Gonerino Settings");
    __weak typeof(self) weakManager = self;
    [sectionItems addObject:[%c(YTSettingsSectionItem)
                  itemWithTitle:@"Open Gonerino Settings"
               titleDescription:@"Manage filtering, block lists, import/export, and support"
        accessibilityIdentifier:nil
                detailTextBlock:nil
                    selectBlock:^BOOL(__unused YTSettingsCell *cell, __unused NSUInteger index) {
                        SettingsViewController *viewController =
                            [[SettingsViewController alloc] initWithSettingsManager:weakManager];
                        [settingsViewController.navigationController pushViewController:viewController animated:YES];
                        return YES;
                    }]];

    if ([settingsViewController respondsToSelector:@selector(setSectionItems:forCategory:title:icon:titleDescription:headerHidden:)]) {
        YTIIcon *icon = [%c(YTIIcon) new];
        icon.iconType = YT_FILTER;
        [settingsViewController setSectionItems:sectionItems
                                    forCategory:Section
                                          title:@"Gonerino"
                                           icon:icon
                               titleDescription:nil
                                   headerHidden:NO];
    } else {
        [settingsViewController setSectionItems:sectionItems
                                    forCategory:Section
                                          title:@"Gonerino"
                               titleDescription:nil
                                   headerHidden:NO];
    }
}

- (void)updateSectionForCategory:(NSUInteger)category withEntry:(id)entry {
    if (category == Section) {
        [self updateSectionWithEntry:entry];
        return;
    }
    %orig;
}

%new
- (void)reloadSection {
    dispatch_async(dispatch_get_main_queue(), ^{
        YTSettingsViewController *settingsViewController = SettingsViewControllerForManager(self);
        if (![settingsViewController isKindOfClass:%c(YTSettingsViewController)])
            return;
        [self updateSectionWithEntry:nil];
        if ([settingsViewController respondsToSelector:@selector(reloadData)])
            [settingsViewController reloadData];
    });
}

%end

%hook YTAppSettingsGroupPresentationData

+ (NSArray *)orderedGroups {
    NSArray *groups = %orig;
    for (YTSettingsGroupData *group in groups) {
        if (group.type == Group)
            return groups;
    }

    NSMutableArray *mutableGroups = groups.mutableCopy ?: [NSMutableArray array];
    [mutableGroups insertObject:[[%c(YTSettingsGroupData) alloc] initWithGroupType:Group] atIndex:0];
    return mutableGroups.copy;
}

%end

%hook YTSettingsGroupData

- (NSString *)titleForSettingGroupType:(NSUInteger)type {
    if (type == Group)
        return @"Gonerino";
    return %orig;
}

- (NSArray *)orderedCategoriesForGroupType:(NSUInteger)type {
    if (type == Group)
        return @[@(Section)];
    return %orig;
}

%end

%hook YTSettingsViewController

- (void)loadWithModel:(id)model {
    %orig;
    YTSettingsSectionItemManager *manager = [self valueForKey:@"_sectionItemManager"];
    if ([manager respondsToSelector:@selector(updateSectionWithEntry:)])
        [manager updateSectionWithEntry:nil];
}

%end

%ctor {
    %init;
}
