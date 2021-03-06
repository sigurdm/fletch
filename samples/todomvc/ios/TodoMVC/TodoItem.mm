// Copyright (c) 2015, the Fletch project authors. Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE.md file.

#import "TodoItem.h"

@implementation TodoItem

- (void)dispatchDeleteEvent {
  TodoMVCPresenter::dispatch(self.deleteEvent);
}

- (void)dispatchCompleteEvent {
  TodoMVCPresenter::dispatch(self.completeEvent);
}

- (void)dispatchUncompleteEvent {
  TodoMVCPresenter::dispatch(self.uncompleteEvent);
}

@end
