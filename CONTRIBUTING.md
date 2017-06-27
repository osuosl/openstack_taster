# Contributing
If at some point in the future more features need to be added, please follow this guide.
`openstack_taster` was designed to make it easier for future developers to add features easily.

1. Flags  
If you want to add a flag to the tool, add an `opts.on` statement to the `OptionParser` block.
Here you can specify the short and long version of the flag as well as the description.
A block can be added to `opts.on` so that once it parses the flag, any code inside the block will run.

2. Test Suites  
If you want to add a test suite to `openstack_taster`, then there are only 3 things you need to do:
  1. Add a suite name and description to the `suites` hash. Do not use spaces.
  2. Add this line in `lib/openstack_taster.rb:taste`: `return_values.push taste_<suite_name>(<parameters>) if settings[:<suite_name>]`  
      `<suite_name>` is the name of your suite defined in the `suites` hash in `bin/openstack_taster`.
  3. Add your function to `lib/openstack_taste.rb`. The standard for suite function names is `taste_<suite_name>`.
