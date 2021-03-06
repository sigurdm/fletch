// Copyright (c) 2015, the Fletch project authors. Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE.md file.

package com.google.fletch.githubmock;

import fletch.FletchApi;

public class DartRunner implements Runnable {
  DartRunner(byte[] snapshot) {
    this.snapshot = snapshot;
  }

  @Override
  public void run() {
    FletchApi.RunSnapshot(snapshot);
  }

  byte[] snapshot;
}
