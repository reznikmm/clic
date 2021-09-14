with Ada.Command_Line;
with GNAT.Command_Line; use GNAT.Command_Line;
with GNAT.OS_Lib;
with GNAT.Strings;

with Ada.Containers.Hashed_Maps;
with Ada.Strings.Unbounded; use Ada.Strings.Unbounded;
with Ada.Strings.Unbounded.Hash;

with AAA.Table_IO;
with AAA.Text_IO;

package body CLIC.Subcommand.Instance is

   package Command_Maps is new Ada.Containers.Hashed_Maps
     (Key_Type        => Ada.Strings.Unbounded.Unbounded_String,
      Element_Type    => Command_Access,
      Hash            => Ada.Strings.Unbounded.Hash,
      Equivalent_Keys => Ada.Strings.Unbounded."=");

   package Topic_Maps is new Ada.Containers.Hashed_Maps
     (Key_Type        => Ada.Strings.Unbounded.Unbounded_String,
      Element_Type    => Help_Topic_Access,
      Hash            => Ada.Strings.Unbounded.Hash,
      Equivalent_Keys => Ada.Strings.Unbounded."=");

   package Group_Maps is new Ada.Containers.Hashed_Maps
     (Key_Type        => Ada.Strings.Unbounded.Unbounded_String,
      Element_Type    => AAA.Strings.Vector,
      "="             => AAA.Strings."=",
      Hash            => Ada.Strings.Unbounded.Hash,
      Equivalent_Keys => Ada.Strings.Unbounded."=");

   package Alias_Maps is new Ada.Containers.Hashed_Maps
     (Key_Type        => Ada.Strings.Unbounded.Unbounded_String,
      Element_Type    => AAA.Strings.Vector,
      "="             => AAA.Strings."=",
      Hash            => Ada.Strings.Unbounded.Hash,
      Equivalent_Keys => Ada.Strings.Unbounded."=");

   Registered_Commands : Command_Maps.Map;
   --  A map of commands based on their names

   Registered_Topics : Topic_Maps.Map;
   --  A map of topics based on their names

   Registered_Groups : Group_Maps.Map;
   --  A map of list of commands based on their group names

   Registered_Aliases : Alias_Maps.Map;
   --  A map of aliases and their replacement args

   Not_In_A_Group   : AAA.Strings.Vector;
   --  List of commands that are not in a group

   Global_Arguments : AAA.Strings.Vector;
   --  Vector of arguments for the global command, the first one should be the
   --  command name, otherwise there is an invalid global switch on the command
   --  line.

   Help_Requested  : Boolean;

   Global_Config : Switches_Configuration;

   Global_Parsing_Done : Boolean := False;

   procedure Display_Options
     (Config : Switches_Configuration;
      Title  : String);
   procedure Display_Global_Options;
   function Highlight_Switches (Line : String) return String;
   function What_Command (Str : String := "") return not null Command_Access;
   procedure Put_Line_For_Access (Str : String);
   function To_Argument_List (V : AAA.Strings.Vector)
                              return GNAT.OS_Lib.Argument_List_Access;
   procedure Process_Aliases
     with Pre => not Global_Arguments.Is_Empty;

   -------------------------
   -- Put_Line_For_Access --
   -------------------------

   procedure Put_Line_For_Access (Str : String) is
   begin
      Put_Line (Str);
   end Put_Line_For_Access;

   ----------------------
   -- To_Argument_List --
   ----------------------

   function To_Argument_List (V : AAA.Strings.Vector)
                              return GNAT.OS_Lib.Argument_List_Access
   is
      List : constant GNAT.OS_Lib.Argument_List_Access :=
        new GNAT.Strings.String_List (1 .. V.Count);
   begin
      for Index in List.all'Range loop
         List (Index) := new String'(V (Index));
      end loop;
      return List;
   end To_Argument_List;

   --------------
   -- Register --
   --------------

   procedure Register (Cmd : not null Command_Access) is
      Name : constant Unbounded_String := To_Unbounded_String (Cmd.Name);
   begin
      if Registered_Commands.Contains (Name) then
         raise Command_Already_Defined with Cmd.Name;
      else
         --  Register the command
         Registered_Commands.Insert (Name, Cmd);

         --  This command is not in a group
         Not_In_A_Group.Append (Cmd.Name);
      end if;
   end Register;

   --------------
   -- Register --
   --------------

   procedure Register (Group : String; Cmd : not null Command_Access) is
      Name : constant Unbounded_String := To_Unbounded_String (Cmd.Name);
      Ugroup : constant Unbounded_String := To_Unbounded_String (Group);
   begin
      if Registered_Commands.Contains (Name) then
         raise Command_Already_Defined with Cmd.Name;
      else
         --  Register the command
         Registered_Commands.Insert (Name, Cmd);

         --  Create the group if it doesn't exist yet
         if not Registered_Groups.Contains (Ugroup) then
            Registered_Groups.Insert (Ugroup, AAA.Strings.Empty_Vector);
         end if;

         --  Add this command to the list of commands for the group
         Registered_Groups.Reference (Ugroup).Append (Cmd.Name);
      end if;
   end Register;

   --------------
   -- Register --
   --------------

   procedure Register (Topic : not null Help_Topic_Access) is
      Name : constant Unbounded_String := To_Unbounded_String (Topic.Name);
   begin
      if Registered_Topics.Contains (Name) then
         raise Program_Error;
      else
         Registered_Topics.Insert (Name, Topic);
      end if;
   end Register;

   ---------------
   -- Set_Alias --
   ---------------

   procedure Set_Alias (Alias : Identifier; Replacement : AAA.Strings.Vector)
   is
      Name : constant Unbounded_String := To_Unbounded_String (Alias);
   begin
      Registered_Aliases.Include (Name, Replacement);
   end Set_Alias;

   ------------------
   -- What_Command --
   ------------------

   function What_Command (Str : String := "") return not null Command_Access is
      Name : constant Unbounded_String :=
        To_Unbounded_String (if Str = "" then What_Command else Str);
   begin
      if Registered_Commands.Contains (Name) then
         return Registered_Commands.Element (Name);
      else
         raise Error_No_Command;
      end if;
   end What_Command;

   ------------------
   -- What_Command --
   ------------------

   function What_Command return String is
   begin
      if Global_Arguments.Is_Empty
        or else
          AAA.Strings.Has_Prefix (Global_Arguments.First_Element, "-")
      then
         raise Error_No_Command;
      else
         return Global_Arguments.First_Element;
      end if;
   end What_Command;

   ----------------------------
   -- Display_Valid_Commands --
   ----------------------------

   procedure Display_Valid_Commands is
      use Command_Maps;
      use Group_Maps;

      Tab   : constant String (1 .. 1) := (others => ' ');
      Table : AAA.Table_IO.Table;

      -----------------
      -- Add_Command --
      -----------------

      procedure Add_Command (Cmd : not null Command_Access) is
      begin
         Table.New_Row;
         Table.Append (Tab);
         Table.Append (TTY_Description (Cmd.Name));
         Table.Append (Tab);
         Table.Append (Cmd.Short_Description);
      end Add_Command;

      First_Group : Boolean := Not_In_A_Group.Is_Empty;
   begin
      if Registered_Commands.Is_Empty then
         return;
      end if;

      Put_Line (TTY_Chapter ("COMMANDS"));

      for Name of Not_In_A_Group loop
         Add_Command (Registered_Commands (To_Unbounded_String (Name)));
      end loop;

      for Iter in Registered_Groups.Iterate loop

         if not First_Group then
            Table.New_Row;
            Table.Append (Tab);
         else
            First_Group := False;
         end if;

         declare
            Group : constant String := To_String (Key (Iter));
         begin
            Table.New_Row;
            Table.Append (Tab);
            Table.Append (TTY_Underline (Group));
            for Name of Element (Iter) loop
               Add_Command (Registered_Commands (To_Unbounded_String (Name)));
            end loop;
         end;
      end loop;

      Table.Print (Separator => "  ", Put_Line => Put_Line_For_Access'Access);
   end Display_Valid_Commands;

   --------------------------
   -- Display_Valid_Topics --
   --------------------------

   procedure Display_Valid_Topics is
      Tab   : constant String (1 .. 1) := (others => ' ');
      Table : AAA.Table_IO.Table;
      use Topic_Maps;

   begin
      if Registered_Topics.Is_Empty then
         return;
      end if;

      Put_Line (TTY_Chapter ("TOPICS"));

      for Elt in Registered_Topics.Iterate loop
         Table.New_Row;
         Table.Append (Tab);
         Table.Append (TTY_Description (To_String (Key (Elt))));
         Table.Append (Tab);
         Table.Append (Element (Elt).Title);
      end loop;

      Table.Print (Separator => "  ", Put_Line =>  Put_Line_For_Access'Access);
   end Display_Valid_Topics;

   ---------------------
   -- Display_Aliases --
   ---------------------

   procedure Display_Aliases is
      Tab   : constant String (1 .. 1) := (others => ' ');
      Table : AAA.Table_IO.Table;
      use Alias_Maps;

   begin
      if Registered_Aliases.Is_Empty then
         return;
      end if;

      Put_Line (TTY_Chapter ("ALIASES"));

      for Elt in Registered_Aliases.Iterate loop
         Table.New_Row;
         Table.Append (Tab);
         Table.Append (TTY_Description (To_String (Key (Elt))));
         Table.Append (Tab);
         Table.Append (Element (Elt).Flatten);
      end loop;

      Table.Print (Separator => "  ", Put_Line =>  Put_Line_For_Access'Access);
   end Display_Aliases;

   -------------------
   -- Display_Usage --
   -------------------

   procedure Display_Usage (Cmd : not null Command_Access) is
      Config  : Switches_Configuration;
      Canary1 : Switches_Configuration;
      Canary2 : Switches_Configuration;
   begin
      Put_Line (TTY_Chapter ("SUMMARY"));
      Put_Line ("   " & Cmd.Short_Description);

      Put_Line ("");
      Put_Line (TTY_Chapter ("USAGE"));
      Put ("   ");
      Put_Line
        (TTY_Underline (Main_Command_Name) &
           " " &
         TTY_Underline (Cmd.Name) &
         " [options] " &
         Cmd.Usage_Custom_Parameters);

      --  We use the following two canaries to detect if a command is adding
      --  its own switches, in which case we need to show their specific help.

      Set_Global_Switches (Canary1); -- For comparison
      Set_Global_Switches (Canary2); -- For comparison
      Cmd.Setup_Switches (Canary1);

      if Get_Switches (Canary1.GNAT_Cfg) /= Get_Switches (Canary2.GNAT_Cfg)
      then
         Cmd.Setup_Switches (Config);
      end if;

      --  Without the following line, GNAT.Display_Help causes a segfault for
      --  reasons I'm unable to pinpoint. This way it prints a harmless blank
      --  line that we want anyway.

      Define_Switch (Config, " ", " ", " ", " ", " ");

      Display_Options (Config, "OPTIONS");

      Display_Global_Options;

      --  Format and print the long command description
      Put_Line ("");
      Put_Line (TTY_Chapter ("DESCRIPTION"));

      for Line of Cmd.Long_Description loop
         AAA.Text_IO.Put_Paragraph (Highlight_Switches (Line),
                                    Line_Prefix => "   ");
         --  GNATCOLL.Paragraph_Filling seems buggy at the moment, otherwise
         --  it would be the logical choice.
      end loop;
   end Display_Usage;

   -------------------
   -- Display_Usage --
   -------------------

   procedure Display_Usage (Displayed_Error : Boolean := False) is
   begin
      if not Displayed_Error then
         Put_Line (Main_Command_Name & " " & TTY_Version (Version));
         Put_Line ("");
      end if;

      Put_Line (TTY_Chapter ("USAGE"));
      Put_Line ("   " & TTY_Underline (Main_Command_Name) &
                  " [global options] " &
                  "<command> [command options] [<arguments>]");
      Put_Line ("");
      Put_Line ("   " & TTY_Underline (Main_Command_Name) & " " &
                        TTY_Underline ("help") &
                        " [<command>|<topic>]");

      Put_Line ("");
      Put_Line (TTY_Chapter ("ARGUMENTS"));
      declare
         Tab   : constant String (1 .. 1) := (others => ' ');
         Table : AAA.Table_IO.Table;
      begin
         Table.New_Row;
         Table.Append (Tab);
         Table.Append (TTY_Description ("<command>"));
         Table.Append ("Command to execute");

         Table.New_Row;
         Table.Append (Tab);
         Table.Append (TTY_Description ("<arguments>"));
         Table.Append ("List of arguments for the command");

         Table.Print (Separator => "   ",
                      Put_Line  => Put_Line_For_Access'Access);
      end;

      Display_Global_Options;
      Display_Valid_Commands;
      Display_Valid_Topics;
      Display_Aliases;
   end Display_Usage;

   ---------------------------
   -- Parse_Global_Switches --
   ---------------------------

   procedure Parse_Global_Switches
     (Command_Line : AAA.Strings.Vector := AAA.Strings.Empty_Vector)
   is

      ----------------------
      -- Ada_Command_Line --
      ----------------------

      function Ada_Command_Line return AAA.Strings.Vector is
         use Ada.Command_Line;

         Result : AAA.Strings.Vector;
      begin
         for I in 1 .. Argument_Count loop
            Result.Append (Ada.Command_Line.Argument (I));
         end loop;
         return Result;
      end Ada_Command_Line;

      ----------------------
      -- Filter_Arguments --
      ----------------------

      function Filter_Arguments return GNAT.OS_Lib.Argument_List_Access is
         use Ada.Command_Line;

         Arguments : AAA.Strings.Vector;

         Cmd_Line : constant AAA.Strings.Vector :=
           (if Command_Line.Is_Empty then Ada_Command_Line else Command_Line);

      begin
         --  GNAT switch handling intercepts -h/--help. To have the same output
         --  for '<main> -h command' and '<main> help command', we do manual
         for Arg of Cmd_Line loop
            if Arg not in "-h" | "--help" then
               Arguments.Append (Arg);
            else
               Help_Requested := True;
            end if;
         end loop;
         return To_Argument_List (Arguments);
      end Filter_Arguments;

      Arguments : GNAT.OS_Lib.Argument_List_Access;
      Parser    : Opt_Parser;
   begin

      --  Only do the global parsing once
      if Global_Parsing_Done and then Command_Line.Is_Empty then
         return;
      else
         Global_Arguments.Clear;
         Help_Requested := False;
         Clear (Global_Config);
         Global_Parsing_Done := True;
      end if;

      --  We filter the command line arguments to remove -h/--help that would
      --  trigger the Getopt automatic help system.
      Arguments := Filter_Arguments;

      Set_Global_Switches (Global_Config);

      --  Run the parser first with only the global switches. With the
      --  Stop_At_First_Non_Switch => True the parser will stop at the first
      --  argument, witch is supposed to be a sub-command, topic, or alias.
      --  The rest of the command line args are added to the Global_Arguments.
      Initialize_Option_Scan (Parser,
                              Arguments,
                              Stop_At_First_Non_Switch => True);

      Getopt (Global_Config.GNAT_Cfg, Parser => Parser);

      --  Make a vector of arguments starting from the first non switch
      loop
         declare
            Arg : constant String :=
              GNAT.Command_Line.Get_Argument (Parser => Parser);
         begin
            exit when Arg = "";
            Global_Arguments.Append (Arg);
         end;
      end loop;

      GNAT.OS_Lib.Free (Arguments);

      --  At this point the command and all unknown switches are in
      --  Global_Arguments.

   exception
      when Exit_From_Command_Line | Invalid_Switch | Invalid_Parameter =>
         Put_Line ("");
         Put_Line ("Use """ & Main_Command_Name &
                     " help <command>"" for specific command help");
         Error_Exit (1);
   end Parse_Global_Switches;

   ---------------------
   -- Process_Aliases --
   ---------------------

   procedure Process_Aliases is
      Name : constant String := Global_Arguments.First_Element;
      Uname : constant Unbounded_String := To_Unbounded_String (Name);
   begin

      --  If we have a valid alias
      if Registered_Aliases.Contains (Uname) then

         --  Remove the alias from the arguments
         Global_Arguments.Delete_First;

         --  And replace it by the alias value
         Global_Arguments.Prepend (Registered_Aliases (Uname));
      end if;
   end Process_Aliases;

   -------------
   -- Execute --
   -------------

   procedure Execute
     (Command_Line : AAA.Strings.Vector := AAA.Strings.Empty_Vector)
   is
   begin

      Parse_Global_Switches (Command_Line);

      if Global_Arguments.Is_Empty then
         --  We should at least have the sub-command name in the arguments
         Display_Usage;
         Error_Exit (1);

      elsif Help_Requested then
         Display_Help (Global_Arguments.First_Element);
         Error_Exit (0);
      end if;

      --  Take care of a potential alias
      Process_Aliases;

      --  Dispatch to the appropriate command

      declare
         Cmd : constant not null Command_Access := What_Command;
         --  Might raise if invalid, if so we are done

         Command_Config  : Switches_Configuration;

         Sub_Cmd_Line : GNAT.OS_Lib.String_List_Access :=
           To_Argument_List (Global_Arguments);
         --  Make a new command line argument list from the remaining arguments
         --  and switches after global parsing.

         Parser : Opt_Parser;

         Sub_Arguments : AAA.Strings.Vector;
      begin

         --  Add command specific switches to the config. We don't need the
         --  global switches because they have been parsed before.
         Cmd.Setup_Switches (Command_Config);

         if Cmd.Switches_As_Args then

            --  Skip sub-command switch parsing as requested by the command
            Sub_Arguments := Global_Arguments;
         else

            --  Initialize a new switch parser that will only see the new
            --  sub-command line (i.e. the remaining args and switches after
            --  global parsing).
            Initialize_Option_Scan (Parser, Sub_Cmd_Line);

            --  Parse sub-command line, invalid switches will raise an
            --  exception
            Getopt (Command_Config.GNAT_Cfg, Parser => Parser);

            --  Make a vector of arguments for the sub-command (every element
            --  that was not a switch in the sub-command line).
            loop
               declare
                  Arg : constant String :=
                    GNAT.Command_Line.Get_Argument (Parser => Parser);
               begin
                  exit when Arg = "";
                  Sub_Arguments.Append (Arg);
               end;
            end loop;
         end if;

         --  We don't need this anymore
         GNAT.OS_Lib.Free (Sub_Cmd_Line);

         pragma Assert (not Sub_Arguments.Is_Empty,
                        "Should have at least the command name");

         --  Remove the sub-command name from the list
         Sub_Arguments.Delete_First;
         Cmd.Execute (Sub_Arguments);
      end;

   exception
      when Exit_From_Command_Line | Invalid_Switch | Invalid_Parameter =>
         --  Getopt has already displayed some help
         Put_Line ("");
         Put_Line ("Use """ & Main_Command_Name &
                     " help <command>"" for specific command help");
         Error_Exit (1);
      when Error_No_Command =>
         Put_Error ("Unrecognized command: " & Global_Arguments.First_Element);
         Put_Line ("");
         Display_Usage (Displayed_Error => True);
         Error_Exit (1);
   end Execute;

   ------------------------
   -- Highlight_Switches --
   ------------------------

   function Highlight_Switches (Line : String) return String is

      use AAA.Strings.Vectors;
      use AAA.Strings;

      ---------------
      -- Highlight --
      ---------------
      --  Avoid highlighting non-alphanumeric characters
      function Highlight (Word : String) return String is
         subtype Valid_Chars is Character with
           Dynamic_Predicate => Valid_Chars in '0' .. '9' | 'a' .. 'z';
         I : Natural := Word'Last; -- last char to highlight
      begin
         while I >= Word'First and then Word (I) not in Valid_Chars loop
            I := I - 1;
         end loop;

         return TTY_Emph (Word (Word'First .. I)) & Word (I + 1 .. Word'Last);
      end Highlight;

      Words : AAA.Strings.Vector := AAA.Strings.Split (Line, Separator => ' ');
      I, J  : Vectors.Cursor;
   begin
      I := Words.First;
      while Has_Element (I) loop
         declare
            Word : constant String := Element (I);
         begin
            J := Next (I);
            if Has_Prefix (Word, "--") and then Word'Length > 2
            then
               Words.Insert (Before => J, New_Item => Highlight (Word));
               Words.Delete (I);
            end if;
            I := J;
         end;
      end loop;
      return Flatten (Words);
   end Highlight_Switches;

   ---------------------
   -- Display_Options --
   ---------------------

   procedure Display_Options
     (Config : Switches_Configuration;
      Title  : String)
   is
      Tab     : constant String (1 .. 1) := (others => ' ');
      Table   : AAA.Table_IO.Table;

      Has_Printable_Rows : Boolean := False;

      -----------------
      -- Without_Arg --
      -----------------

      function Without_Arg (Value : String) return String is
         Required_Character : constant Character := Value (Value'Last);
      begin
         return
            (if Required_Character in '=' | ':' | '!' | '?' then
               Value (Value'First .. Value'Last - 1)
             else
               Value);
      end Without_Arg;

      --------------
      -- With_Arg --
      --------------

      function With_Arg (Value, Arg : String) return String is
         Required_Character : constant Character := Value (Value'Last);
      begin
         return
            (if Required_Character in '=' | ':' | '!' | '?' then
                AAA.Strings.Replace
                 (Value,
                  "" & Required_Character,
                  (case Required_Character is
                     when '=' => "=" & Arg,
                     when ':' => "[ ] " & Arg,
                     when '!' => Arg,
                     when '?' => "[" & Arg & "]",
                     when others => raise Program_Error))
            else Value);
      end With_Arg;

      ---------------
      -- Print_Row --
      ---------------

      procedure Print_Row (Short_Switch, Long_Switch, Arg, Help : String) is
         Has_Short : constant Boolean := Short_Switch not in " " | "";
         Has_Long  : constant Boolean := Long_Switch not in " " | "";
      begin
         if not Has_Short and then not Has_Long then
            return;
         end if;

         Table.New_Row;
         Table.Append (Tab);

         if Has_Short and Has_Long then
            Table.Append (TTY_Description (Without_Arg (Short_Switch)) &
              " (" & With_Arg (Long_Switch, Arg) & ")");
         elsif not Has_Short and Has_Long then
            Table.Append (TTY_Description (With_Arg (Long_Switch, Arg)));
         elsif Has_Short and not Has_Long then
            Table.Append (TTY_Description (With_Arg (Short_Switch, Arg)));
         end if;

         Table.Append (Help);

         Has_Printable_Rows := True;
      end Print_Row;
   begin
      for Elt of Config.Info loop
         Print_Row (To_String (Elt.Switch),
                    To_String (Elt.Long_Switch),
                    To_String (Elt.Argument),
                    To_String (Elt.Help));
      end loop;

      if Has_Printable_Rows then
         Put_Line ("");
         Put_Line (TTY_Chapter (Title));

         Table.Print (Separator => "  ",
                      Put_Line  => Put_Line_For_Access'Access);
      end if;
   end Display_Options;

   ----------------------------
   -- Display_Global_Options --
   ----------------------------

   procedure Display_Global_Options is
      Global_Config   : Switches_Configuration;
   begin
      Set_Global_Switches (Global_Config);
      Display_Options (Global_Config, "GLOBAL OPTIONS");
   end Display_Global_Options;

   ------------------
   -- Display_Help --
   ------------------

   procedure Display_Help (Keyword : String) is

      ------------
      -- Format --
      ------------

      procedure Format (Text : AAA.Strings.Vector) is
      begin
         for Line of Text loop
            AAA.Text_IO.Put_Paragraph (Highlight_Switches (Line),
                                       Line_Prefix => "   ");
         end loop;
      end Format;

      Ukey : constant Unbounded_String := To_Unbounded_String (Keyword);
   begin
      if Registered_Commands.Contains (Ukey) then
         Display_Usage (What_Command (Keyword));

      elsif Registered_Topics.Contains (Ukey) then
         Put_Line (TTY_Chapter (Registered_Topics.Element (Ukey).Title));
         Format (Registered_Topics.Element (Ukey).Content);
      elsif Registered_Aliases.Contains (Ukey) then
         Put_Line ("'" & Keyword & "' is an alias for: '" &
                     Main_Command_Name & " " &
                     Registered_Aliases.Element (Ukey).Flatten & "'");
      else
         Put_Error ("No help found for: " & Keyword);
         Display_Global_Options;
         Display_Valid_Commands;
         Display_Valid_Topics;
         Display_Aliases;
         Error_Exit (1);
      end if;
   end Display_Help;

   -------------
   -- Execute --
   -------------

   overriding
   procedure Execute (This : in out Builtin_Help;
                      Args :        AAA.Strings.Vector)
   is
      pragma Unreferenced (This);
   begin
      if Args.Count /= 1 then
         if Args.Count > 1 then
            Put_Error ("Please specify a single help keyword");
            Put_Line ("");
         end if;

         Put_Line (TTY_Chapter ("USAGE"));
         Put_Line ("   " & TTY_Underline (Main_Command_Name) & " " &
           TTY_Underline ("help") & " [<command>|<topic>]");

            Put_Line ("");
         Put_Line (TTY_Chapter ("ARGUMENTS"));
         declare
            Tab   : constant String (1 .. 1) := (others => ' ');
            Table : AAA.Table_IO.Table;
         begin
            Table.New_Row;
            Table.Append (Tab);
            Table.Append (TTY_Description ("<command>"));
            Table.Append ("Command for which to show a description");

            Table.New_Row;
            Table.Append (Tab);
            Table.Append (TTY_Description ("<topic>"));
            Table.Append ("Topic for which to show a description");

            Table.Print (Separator => "  ",
                         Put_Line  => Put_Line_For_Access'Access);
         end;

         Display_Global_Options;
         Display_Valid_Commands;
         Display_Valid_Topics;
         Display_Aliases;
         Error_Exit (1);
      end if;

      Display_Help (Args (1));
   end Execute;

end CLIC.Subcommand.Instance;
