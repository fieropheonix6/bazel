// Copyright 2022 The Bazel Authors. All rights reserved.
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//    http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.
//

package com.google.devtools.build.lib.bazel.bzlmod;

import com.google.common.collect.ImmutableMap;
import com.google.devtools.build.lib.bazel.bzlmod.ModuleFileValue.RootModuleFileValue;
import com.google.devtools.build.lib.bazel.repository.RepositoryOptions.CheckDirectDepsMode;
import com.google.devtools.build.lib.events.Event;
import com.google.devtools.build.lib.server.FailureDetails.ExternalDeps.Code;
import com.google.devtools.build.lib.skyframe.PrecomputedValue.Precomputed;
import com.google.devtools.build.skyframe.SkyFunction;
import com.google.devtools.build.skyframe.SkyFunctionException;
import com.google.devtools.build.skyframe.SkyFunctionException.Transience;
import com.google.devtools.build.skyframe.SkyKey;
import com.google.devtools.build.skyframe.SkyValue;
import java.util.Map;
import java.util.Objects;
import javax.annotation.Nullable;

/**
 * Runs Bazel module resolution. This function produces the dependency graph containing all Bazel
 * modules, along with a few lookup maps that help with further usage. By this stage, module
 * extensions are not evaluated yet.
 */
public class BazelModuleSelectionFunction implements SkyFunction {

  public static final Precomputed<CheckDirectDepsMode> CHECK_DIRECT_DEPENDENCIES =
      new Precomputed<>("check_direct_dependency");

  @Override
  @Nullable
  public SkyValue compute(SkyKey skyKey, Environment env)
      throws SkyFunctionException, InterruptedException {

    RootModuleFileValue root =
        (RootModuleFileValue) env.getValue(ModuleFileValue.KEY_FOR_ROOT_MODULE);
    if (root == null) {
      return null;
    }
    ImmutableMap<ModuleKey, Module> initialDepGraph = Discovery.run(env, root);
    if (initialDepGraph == null) {
      return null;
    }

    BazelModuleSelectionValue selectionResultValue;
    try {
      selectionResultValue = Selection.run(initialDepGraph, root.getOverrides());
    } catch (ExternalDepsException e) {
      throw new BazelModuleResolutionFunctionException(e, Transience.PERSISTENT);
    }

    verifyRootModuleDirectDepsAreAccurate(
        env,
        initialDepGraph.get(ModuleKey.ROOT),
        selectionResultValue.getResolvedDepGraph().get(ModuleKey.ROOT));

    return selectionResultValue;
  }

  private static void verifyRootModuleDirectDepsAreAccurate(
      Environment env, Module discoveredRootModule, Module resolvedRootModule)
      throws InterruptedException, BazelModuleResolutionFunctionException {
    CheckDirectDepsMode mode = Objects.requireNonNull(CHECK_DIRECT_DEPENDENCIES.get(env));
    if (mode == CheckDirectDepsMode.OFF) {
      return;
    }
    boolean failure = false;
    for (Map.Entry<String, ModuleKey> dep : discoveredRootModule.getDeps().entrySet()) {
      ModuleKey resolved = resolvedRootModule.getDeps().get(dep.getKey());
      if (!dep.getValue().equals(resolved)) {
        String message =
            String.format(
                "For repository '%s', the root module requires module version %s, but got %s in the"
                    + " resolved dependency graph.",
                dep.getKey(), dep.getValue(), resolved);
        if (mode == CheckDirectDepsMode.WARNING) {
          env.getListener().handle(Event.warn(message));
        } else {
          env.getListener().handle(Event.error(message));
          failure = true;
        }
      }
    }
    if (failure) {
      throw new BazelModuleResolutionFunctionException(
          ExternalDepsException.withMessage(
              Code.VERSION_RESOLUTION_ERROR, "Direct dependency check failed."),
          Transience.PERSISTENT);
    }
  }


  static class BazelModuleResolutionFunctionException extends SkyFunctionException {
    BazelModuleResolutionFunctionException(ExternalDepsException e, Transience transience) {
      super(e, transience);
    }
  }
}
