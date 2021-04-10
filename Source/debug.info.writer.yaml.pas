unit debug.info.writer.yaml;

(*
 * Copyright (c) 2021 Anders Melander
 *
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at http://mozilla.org/MPL/2.0/.
 *)

{$RTTI EXPLICIT METHODS([]) PROPERTIES([]) FIELDS([])}
{$define WRITE_LINES}
{$define WRITE_SYMBOLS}
{.$define WRITE_PUBLICS} // Doesn't work and llvm-pdbutil doesn't support it properly

interface

uses
  Classes,
  debug.info,
  debug.info.writer;

type
  // YAML writer for use with the LLVM project's llvm-pdbutil yaml2pdb
  TDebugInfoYamlWriter = class(TDebugInfoWriter)
  private
  protected
  public
    procedure SaveToStream(Stream: TStream; DebugInfo: TDebugInfo); override;
  end;


implementation


uses
  SysUtils,
  Types,
  debug.info.pdb;

{ TDebugInfoYamlWriter }

procedure TDebugInfoYamlWriter.SaveToStream(Stream: TStream; DebugInfo: TDebugInfo);
var
  Level: integer;
  Writer: TStreamWriter;

  procedure WriteLine(const s: string); overload;
  begin
    if (Level > 0) then
      Writer.Write(StringOfChar(' ', Level * 2));
    Writer.WriteLine(s);
  end;

  procedure WriteLine(const Fmt: string; const Args: array of const); overload;
  begin
    WriteLine(Format(Fmt, Args));
  end;

  procedure BeginBlock(const s: string); overload;
  begin
    WriteLine(s);
    Inc(Level);
  end;

  procedure BeginBlock(const Fmt: string; const Args: array of const); overload;
  begin
    BeginBlock(Format(Fmt, Args));
  end;

  procedure EndBlock;
  begin
    Dec(Level);
  end;

begin
  Logger.Info('Writing YAML file');

  Writer := TStreamWriter.Create(Stream);
  try

    Level := 0;

    WriteLine('---');
    WriteLine(Format('# generated by map2yaml %s', [DateTimeToStr(Now)]));

    (*
    ** PDB (PDB Info) stream
    *)
    BeginBlock('PdbStream:');
    begin
      // llvm-pdbutil swaps the values in the GUID that have endianess
      // (this is a bug) so we need to save them "pre-swapped" in the
      // YAML file in order to get the correct value in the PDB file.
      var TweakedSignature := PdbBuildSignature;
      var Bytes := TweakedSignature.ToByteArray(TEndian.Little);
      TweakedSignature := TGUID.Create(Bytes, TEndian.Big);

      WriteLine('Age: %d', [PdbBuildAge]);
      WriteLine('Guid: ''%s''', [TweakedSignature.ToString]);
      WriteLine('Signature: 1537453107'); // Value doesn't matter
      WriteLine('Features: [ MinimalDebugInfo ]');
//      WriteLine('Features: [ VC110 ]');
      WriteLine('Version: VC70');
    end;
    EndBlock;


    (*
    ** DBI (Debug Info) stream
    *)
    BeginBlock('DbiStream:');
    begin
      WriteLine('VerHeader: V70');
      WriteLine('Age: %d', [PdbBuildAge]);
//      WriteLine('MachineType: Amd64');
      WriteLine('Flags: 0'); // 2 = private symbols were stripped

      BeginBlock('Modules:');
      begin

        for var Module in DebugInfo.Modules do
        begin
          // Skip module if it doesn't contain any usable source lines
          if (Module.SourceLines.Empty) then
            continue;

          // Skip module if it doesn't contain code
          if (not (Module.Segment.SegClassType in [sctCODE, sctICODE])) then
            continue;

          Logger.Info(Format('- Module: %s', [Module.Name]));

          BeginBlock('- Module: ''%s''', [Module.Name]);
          begin
            WriteLine('ObjFile: ''%s.dcu''', [Module.Name]);

            BeginBlock('SourceFiles:');
            begin
              for var SourceFile in Module.SourceFiles do
                WriteLine('- ''%s''', [SourceFile.Filename]);
            end;
            EndBlock;

            BeginBlock('Subsections:');
            begin

              BeginBlock('- !FileChecksums');
              begin
                BeginBlock('Checksums:');
                begin
                  for var SourceFile in Module.SourceFiles do
                  begin
                    BeginBlock('- FileName: ''%s''', [SourceFile.Filename]);
                    begin
                      WriteLine('Kind: None');
                      WriteLine('Checksum: ''''');
                    end;
                    EndBlock;
                  end;
                end;
                EndBlock;
              end;
              EndBlock;

{$ifdef WRITE_LINES}
              BeginBlock('- !Lines');
              begin
                WriteLine('CodeSize: %d', [Module.Size]);
                WriteLine('RelocOffset: %0:d # %0:.8X', [Module.Offset]);
                WriteLine('RelocSegment: %d', [Module.Segment.Index]);
                WriteLine('Flags: [ ]');
                BeginBlock('Blocks:');
                begin
                  var LastSourceFile: TDebugInfoSourceFile := nil;
                  for var SourceLine in Module.SourceLines do
                  begin
                    if (SourceLine.SourceFile <> LastSourceFile) then
                    begin
                      if (LastSourceFile <> nil) then
                      begin
                        EndBlock;
                        WriteLine('Columns: [ ]');
                        EndBlock;
                      end;
                      BeginBlock('- FileName: ''%s''', [SourceLine.SourceFile.Filename]);
                      BeginBlock('Lines:');
                      LastSourceFile := SourceLine.SourceFile;
                    end;

                    BeginBlock('- Offset: %d', [SourceLine.Offset]);
                    begin
                      WriteLine('LineStart: %d', [SourceLine.LineNumber]);
                      WriteLine('IsStatement: true');
                      WriteLine('EndDelta: 0');
                    end;
                    EndBlock;
                  end;
                  if (LastSourceFile <> nil) then
                  begin
                    EndBlock;
                    WriteLine('Columns: [ ]');
                    EndBlock;
                  end;
                end;
                EndBlock;
              end;
              EndBlock;
{$endif WRITE_LINES}

            end;
            EndBlock;

{$ifdef WRITE_SYMBOLS}
            (*
            ** Modi (Module Information) stream  - inside the DBI stream
            *)
            BeginBlock('Modi:');
            begin
              WriteLine('Signature: 4'); // 4 = Supposedly means C13 line information
              BeginBlock('Records:');
              begin

                for var Symbol in Module.Symbols do
                begin
                  // Ignore zero size symbols
                  if (Symbol.Size = 0) then
                    continue;

                  BeginBlock('- Kind: S_GPROC32');
                  begin
                    BeginBlock('ProcSym:');
                    begin
                      WriteLine('Segment: %d', [Symbol.Module.Segment.Index]);
                      WriteLine('Offset: %0:d # %0:.8X [%1:.8X]', [Symbol.Offset, Symbol.Module.Segment.Offset+Symbol.Module.Offset+Symbol.Offset]);
                      WriteLine('CodeSize: %d', [Symbol.Size]);
                      WriteLine('DbgStart: 0');
                      WriteLine('DbgEnd: %d', [Symbol.Size-1]);
                      WriteLine('FunctionType: 4097'); // I have no clue...
                      WriteLine('Flags: [ ]');
                      WriteLine('DisplayName: ''%s''', [Symbol.Name]);
                    end;
                    EndBlock;
                  end;
                  EndBlock;

                  (* As far as I can see a S_GPROC32 must be terminated with S_END but it doesn't seem to make a difference.
                  BeginBlock('- Kind: S_END');
                  begin
                    WriteLine('ScopeEndSym: {}');
                  end;
                  EndBlock;
                  *)

                end;
              end;
              EndBlock;
            end;
            EndBlock;
{$endif WRITE_SYMBOLS}

          end;
          EndBlock;
        end;

        (*
        ** Output segments as a special linker module
        *)
        // See: https://reviews.llvm.org/rG28e31ee45e63d7c195e7980c811a15f0b26118cb
        BeginBlock('- Module: ''%s''', ['* Linker *']);
        begin
          WriteLine('ObjFile: ''''');

          BeginBlock('Modi:');
          begin
            WriteLine('Signature: 4');

            BeginBlock('Records:');
            begin
              BeginBlock('- Kind: S_OBJNAME');
              begin
                BeginBlock('ObjNameSym:');
                begin
                  WriteLine('Signature: 0');
                  WriteLine('ObjectName: ''* Linker *''');
                end;
                EndBlock;
              end;
              EndBlock;

              BeginBlock('- Kind: S_COMPILE3');
              begin
                BeginBlock('Compile3Sym:');
                begin
                  WriteLine('Machine: X64');
                  WriteLine('Version: ''Microsoft (R) LINK''');
                  WriteLine('Flags: [ ]');
                  WriteLine('FrontendMajor: 0');
                  WriteLine('FrontendMinor: 0');
                  WriteLine('FrontendBuild: 0');
                  WriteLine('FrontendQFE: 0');
                  WriteLine('BackendMajor: 12');
                  WriteLine('BackendMinor: 0');
                  WriteLine('BackendBuild: 31101');
                  WriteLine('BackendQFE: 0');
                end;
                EndBlock;
              end;
              EndBlock;

              for var SegClassType := Low(TDebugInfoSegmentClass) to High(TDebugInfoSegmentClass) do
              begin
                var Segment := DebugInfo.Segments.FindByClassType(SegClassType);
                if (Segment = nil) then
                  continue;

                BeginBlock('- Kind: S_SECTION');
                begin
                  BeginBlock('SectionSym:');
                  begin
                    WriteLine('SectionNumber: %d', [Segment.Index]);
                    WriteLine('Rva: %d', [Segment.Offset]);
                    WriteLine('Alignment: %d', [12]); // Apparently value is power of 2. Eg. 2^12 = 4096
                    WriteLine('Length: %d', [Segment.Size]);
                    WriteLine('Characteristics: %d', [$60000020]); // TODO
                    WriteLine('Name: %s', [Segment.Name]);
                  end;
                  EndBlock;
                end;
                EndBlock;

                BeginBlock('- Kind: S_COFFGROUP');
                begin
                  BeginBlock('CoffGroupSym:');
                  begin
                    WriteLine('Segment: %d', [Segment.Index]);
                    WriteLine('Offset: %d', [0]); // Apparently relative to the segment
                    WriteLine('Size: %d', [Segment.Size]);
                    WriteLine('Name: %s', [Segment.Name]);
                    WriteLine('Characteristics: %d', [$60000020]); // TODO
                  end;
                  EndBlock;
                end;
                EndBlock;
              end;
            end;
            EndBlock;
          end;
          EndBlock;
        end;
        EndBlock;

      end;
      EndBlock;
    end;
    EndBlock;

    (*
    ** Public stream
    **
    ** According to the LLVM documentation the Public Stream is part of the DBI stream
    ** but llvm-pdbutil pdb2yaml places the PublicsStream section at the outer level, same
    ** as the DBI stream.
    ** Furthermore llvm-pdbutil yaml2pdb requires the same format but the pdb it produces
    ** apparently doesn't contain the Publics Stream, so it doesn't round-trip.
    *)
{$ifdef WRITE_PUBLICS}
    if (Logging) then
      Log('- Symbols');

    BeginBlock('PublicsStream:');
    begin
      BeginBlock('Records:');
      begin
        for var Module in DebugInfo.Modules do
        begin
          // Skip module if it doesn't contain any usable source lines
          if (Module.SourceLines.Empty) then
            continue;

          // Skip module if it doesn't contain code
          if (not (Module.Segment.SegClassType in [sctCODE, sctICODE])) then
            continue;

          for var Symbol in Module.Symbols do
          begin
            // Ignore zero size symbols
            if (Symbol.Size = 0) then
              continue;

            BeginBlock('- Kind: S_PUB32');
            begin
              BeginBlock('PublicSym32:');
              begin
                WriteLine('Flags: [ Function ]');
//                var Offset := Symbol.Module.Segment.Offset+Symbol.Module.Offset+Symbol.Offset;
                var Offset := Symbol.Module.Offset+Symbol.Offset;
                WriteLine('Offset: %0:d # %0:.8X [%1:.8X]', [Offset, Symbol.Offset]);
                WriteLine('Segment: %d', [Symbol.Module.Segment.Value]);
                WriteLine('Name: ''%s''', [Symbol.Name]);
              end;
              EndBlock;
            end;
            EndBlock;

          end;
        end;

      end;
      EndBlock;
    end;
    EndBlock;
{$endif WRITE_PUBLICS}

    WriteLine('...');

  finally
    Writer.Free;
  end;
end;

end.

