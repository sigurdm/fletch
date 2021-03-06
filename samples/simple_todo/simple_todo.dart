// Copyright (c) 2015, the Fletch project authors. Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE.md file.

import 'simple_todo_impl.dart';
import 'generated/dart/simple_todo.dart';

main() {
  var impl = new TodoImpl();
  TodoService.initialize(impl);
  while (TodoService.hasNextEvent()) {
    TodoService.handleNextEvent();
  }
}

