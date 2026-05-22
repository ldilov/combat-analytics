    end
    if suggestion.reasonCode == "DEFENSIVE_DRIFT" then
        local delta = (evidence.current or 0) - (evidence.baseline or 0)
        return string.format("First defensive was %.1fs later than your usual pacing. Damage taken %s.", delta, ns.Helpers.FormatNumber(evidence.damageTaken or 0))
    end
    if suggestion.reasonCode == "MIDNIGHT_SAFE_LIMITS" then
        return "Built from Blizzard's post-combat Damage Meter totals because raw CLEU timing is restricted."
    end
    if suggestion.reasonCode == "RAW_EVENT_OVERFLOW" then
        return string.format("Stored %d events against cap %d.", evidence.rawEvents or 0, evidence.max or 0)
    end
    if suggestion.reasonCode == "DIED_IN_CC" then
        return string.format("CC spell ID %d. Burst taken: %s across %d damage events.", evidence.ccSpellId or 0, ns.Helpers.FormatNumber(evidence.totalBurstDamage or 0), evidence.killingSpellCount or 0)
    end
    if suggestion.reasonCode == "TRINKET_TIMING_POOR" then
        return string.format("CC spell ID %d lasted %.1fs. Trinket lag: %.1fs.", evidence.ccSpellId or 0, evidence.ccDuration or 0, evidence.lagSeconds or 0)
    end
    if suggestion.reasonCode == "HIGH_CC_UPTIME" then
        return string.format("CC uptime %.1f%%. Time under CC: %.1fs.", (evidence.ccUptimePct or 0) * 100, evidence.timeUnderCC or 0)
    end
    if suggestion.reasonCode == "SPEC_WINRATE_DEFICIT" then
        return string.format("Win rate %.0f%% against %s over %d sessions.", (evidence.winRate or 0) * 100, evidence.specName or "this spec", evidence.fights or 0)
    end
    if suggestion.reasonCode == "SPEC_WINRATE_STRENGTH" then
        return string.format("Win rate %.0f%% against %s over %d sessions.", (evidence.winRate or 0) * 100, evidence.specName or "this spec", evidence.fights or 0)
    end
    if suggestion.reasonCode == "SPEC_SCALING_NOTABLE" then
        local scalingInfo = evidence.scalingInfo or {}
        local dmgMod = scalingInfo.damageModifier and string.format("Damage modifier: %.2f", scalingInfo.damageModifier) or ""
        local healMod = scalingInfo.healingModifier and string.format("Healing modifier: %.2f", scalingInfo.healingModifier) or ""
        local sep = (dmgMod ~= "" and healMod ~= "") and ". " or ""
        return string.format("Spec %s has notable PvP scaling. %s%s%s", tostring(evidence.specId or ""), dmgMod, sep, healMod)
    end
    if suggestion.reasonCode == "REACTIVE_DEFENSIVE_LATE" then
        return string.format("Defensive (spell %d) used %.1fs into CC (spell %d). Earlier use reduces burst taken.",
            evidence.cooldownSpellId or 0, evidence.latencySeconds or 0, evidence.ccSpellId or 0)
    end
    if suggestion.reasonCode == "SUBOPTIMAL_OPENER_SEQUENCE" then
        return string.format("Current opener win rate %.0f%% over %d attempts vs %s. A better opener has %.0f%% over %d attempts.",

 succeeded in 1103ms:

LineNumber Line                                                                                                        
---------- ----                                                                                                        
       104     return ns.Widgets.FormatDisplayLabel(value)                                                             
       357     return severity, "Session Trust", body, evidence                                                        
       373             "Fight Story",                                                                                  
       381             "Fight Story",                                                                                  
       393             "Fight Story",                                                                                  
       405             "Fight Story",                                                                                  
       413             "Fight Story",                                                                                  
       421             "Fight Story",                                                                                  
       428         "Fight Story",                                                                                      
       441             "Matchup Memory",                                                                               
       442             "This session does not have a stable opponent identity yet, so matchup memory is intentionall...
       460             "Matchup Memory",                                                                               
       468             "Matchup Memory",                                                                               
       475         "Matchup Memory",                                                                                   
       477         "Three similar sessions is the minimum before matchup memory becomes meaningful."                   
       481 -- T077: Extract compact one-line key-data points from the fight story evidence                             
       513     self.frame = CreateFrame("Frame", nil, parent)                                                          
       517     self.title = ns.Widgets.CreateSectionTitle(self.frame, "Actionable Insights", "TOPLEFT", self.frame, ...
       518     self.caption = ns.Widgets.CreateCaption(self.frame, "Post-fight review for the current character: tru...
       520     self.shell, self.scrollFrame, self.canvas = ns.Widgets.CreateScrollCanvas(self.frame, 808, 410)         
       524     -- T057: Performance Trends placeholder (populated later by TrendAnalyzer)                              
       525     self.trendSection = CreateFrame("Frame", nil, self.canvas)                                              
       530     self.emptyCard = ns.Widgets.CreateInsightCard(self.canvas, 750, 96)                                     
       536     self.trustCard = ns.Widgets.CreateInsightCard(self.canvas, 750, 104)                                    
       540     if ns.Widgets.AddHoverEffect then                                                                       
       541         ns.Widgets.AddHoverEffect(self.trustCard, 0.06)                                                     
       544     self.trustSeverityBar = ns.Widgets.CreateMetricBar(self.canvas, 750, 32)                                
       547     self.trustConfidencePill = ns.Widgets.CreateConfidencePill(self.canvas, "estimated")                    
       553     self.storyCard = ns.Widgets.CreateInsightCard(self.canvas, 750, 104)                                    
       556     if ns.Widgets.AddHoverEffect then                                                                       
       557         ns.Widgets.AddHoverEffect(self.storyCard, 0.06)                                                     
       560     self.storySeverityBar = ns.Widgets.CreateMetricBar(self.canvas, 750, 32)                                
       564     self.degradedImportBanner = ns.Widgets.CreateInsightCard(self.canvas, 750, 68)                          
       569     self.storyPillFrame = CreateFrame("Frame", nil, self.canvas)                                            
       577     self.matchupCard = ns.Widgets.CreateInsightCard(self.canvas, 750, 104)                                  
       580     if ns.Widgets.AddHoverEffect then                                                                       
       581         ns.Widgets.AddHoverEffect(self.matchupCard, 0.06)                                                   
       584     self.matchupSeverityBar = ns.Widgets.CreateMetricBar(self.canvas, 750, 32)                              
       590     self.filterFrame = CreateFrame("Frame", nil, self.canvas)                                               
       598         local btn = ns.Widgets.CreateButton(self.filterFrame, def.label, btnWidth, 24)                      
       614     -- Recent coaching notes section title + caption                                                        
       616     self.recentTitle = ns.Widgets.CreateSectionTitle(self.canvas, "Recent Coaching Notes", "TOPLEFT", sel...
       617     self.recentCaption = ns.Widgets.CreateCaption(self.canvas, "Rules-backed notes from recent sessions o...
       625         local card = ns.Widgets.CreateInsightCard(self.canvas, 750, 108)                                    
       633         if ns.Widgets.AddHoverEffect then                                                                   
       634             ns.Widgets.AddHoverEffect(card, 0.06)                                                           
       637         local severityBar = ns.Widgets.CreateMetricBar(self.canvas, 750, 28)                                
       642     -- Strategy Spotlight section                                                                           
       643     self.strategyTitle = ns.Widgets.CreateSectionTitle(self.canvas, "Strategy Spotlight", "TOPLEFT", self...
       644     self.strategyCaption = ns.Widgets.CreateCaption(self.canvas, "Counter guide for the spec you faced mo...
       646     self.strategyCard = CreateFrame("Frame", nil, self.canvas, "BackdropTemplate")                          
       649     ns.Widgets.ApplyBackdrop(self.strategyCard, ns.Widgets.THEME.panelAlt, ns.Widgets.THEME.border)         
       654     self.strategyCard.specLabel:SetTextColor(unpack(ns.Widgets.THEME.accent))                               
       660     self.strategyCard.ccLabel:SetTextColor(unpack(ns.Widgets.THEME.textMuted))                              
       666     self.strategyCard.threatLabel:SetTextColor(unpack(ns.Widgets.THEME.warning))                            
       673     self.strategyCard.actions:SetTextColor(unpack(ns.Widgets.THEME.text))                                   
       679     self.strategyCard.winRate:SetTextColor(unpack(ns.Widgets.THEME.textMuted))                              
       681     self.strategyEmpty = ns.Widgets.CreateInsightCard(self.canvas, 750, 72)                                 
       687     self.openerLabSection = CreateFrame("Frame", nil, self.canvas, "BackdropTemplate")                      
       688     ns.Widgets.ApplyBackdrop(self.openerLabSection, ns.Widgets.THEME.panelAlt, ns.Widgets.THEME.border)     
       693     self.openerLabTitle:SetTextColor(unpack(ns.Widgets.THEME.text))                                         
       700     self.openerLabSequence:SetTextColor(unpack(ns.Widgets.THEME.text))                                      
       705     self.openerLabRankTitle:SetTextColor(unpack(ns.Widgets.THEME.accent))                                   
       710         row.bar = ns.Widgets.CreateMetricBar(self.openerLabSection, 710, 22)                                
       724     self.practicePlanTitle = ns.Widgets.CreateSectionTitle(self.canvas, "Practice Plan", "TOPLEFT", self....
       725     self.practicePlanCaption = ns.Widgets.CreateCaption(self.canvas, "Actionable practice drills derived ...
       730         local card = ns.Widgets.CreateInsightCard(self.canvas, 750, 108)                                    
       738         local bar = ns.Widgets.CreateMetricBar(self.canvas, 750, 28)                                        
       746     ns.Widgets.SetCanvasHeight(self.canvas, 1900)                                                           
       785             pill = ns.Widgets.CreatePill(self.storyPillFrame, 10, 18, ns.Widgets.THEME.panelAlt, ns.Widge...
       821     -- T073: Populate Performance Trends section from TrendAnalyzer                                         
       840                 header:SetText("Performance Trends")                                                        
       856                     row = CreateFrame("Frame", nil, self.trendSection)                                      
       892             "Once this character has a few fights stored, this tab will surface trust, fight story, match...
       927         self.caption:SetText(string.format("Post-fight review for %s. Trust first, then fight story, matc...
       986         self.caption:SetText("Post-fight review for the current character: trust first, then fight story,...
      1024             if suggestion.severity == "high" and ns.Widgets.AddPulseGlow then                               
      1025                 ns.Widgets.AddPulseGlow(card)                                                               
      1058     -- Strategy Spotlight                                                                                   
      1276     ns.Widgets.SetCanvasHeight(self.canvas, math.max(height, 400))                                          



codex
## Insights: Post-Match Triage

### Vision

Replace the current “trust/story/notes” feed with a coaching dashboard that answers one question: “What should I fix before the next queue?” Trust metadata becomes supporting context, not the main content. The tab should rank problems by impact, confidence, and controllability, then show the user a short timeline-backed explanation and one concrete practice action.

### Layout

Single scroll view, 750-800px content width, built with existing `CreateFrame` and `ns.Widgets`. Top area is a compact two-column summary: left side shows the primary coaching callout, right side shows match context and data quality. Below that, use stacked sections with stable card heights and no extra severity bars between cards. Color is reserved for priority and confidence badges.

### Core sections

- **Next Queue Focus**: one large card with the highest-value recommendation. Shows title, “why it mattered,” “what to do next,” and 2-3 evidence chips. Example: “Trade earlier into stun chains. You died in CC with defensive available; first defensive came 4.8s later than your baseline.”

- **Fight Timeline Read**: compact horizontal sequence: opener, first go, first defensive, first CC chain, death or match end. Each node is labeled “good,” “late,” “missing,” or “unknown.” This replaces the vague Fight Story sentence.

- **Pressure / Survival / Control Scoreboard**: three columns comparing current match vs personal baseline, matchup baseline, and build baseline where available. Each metric shows delta, sample count, and confidence.

- **Matchup Plan**: opponent spec card with historical win rate, common failure pattern, and one counter-action. This folds Strategy Spotlight and Matchup Memory into a usable matchup module.

- **Evidence Drawer**: collapsed-by-default list of all generated suggestions, filterable by Offense, Defense, CC, Matchup, Consistency. This keeps detail available without making the main view a garbage feed.

- **Practice Plan**: 1-3 drills generated from recurring reason codes, not single-session noise. Example: “First defensive drill: review matches where `DEFENSIVE_DRIFT`, `DIED_WITH_DEFENSIVES`, or `REACTIVE_DEFENSIVE_LATE` appeared twice this week.”

### Data wiring

Priority = severity × confidence × recurrence × controllability. Current `suggestions[]` provide reason codes, evidence, severity, effort, and confidence. Timeline uses `rawEvents`, `cooldowns`, `auras`, `spells`, and CC-specific suggestions when CLEU is available. When CLEU is restricted, the timeline shows only reliable anchors from scoreboard totals, cooldown summaries, arena roster, and metric provenance. Baselines come from builds, contexts, opponents, specs, daily/weekly trends, and dummy benchmarks.

### Why this beats current

It leads with coaching value instead of import quality. It turns 30 reason codes into a ranked decision, shows when the addon is guessing, and separates “what happened” from “what to practice.” The user no longer reads eight flat cards and a confidence lecture; they get one focus, one timeline, one matchup plan, and optional evidence.

### Risks

Ranking must avoid overconfidence when Midnight restricts CLEU. Some sessions will only support scoreboard-level advice, so the UI needs explicit “unknown” states. The priority formula may need tuning with real match histories to avoid repeating the same generic recommendation.
tokens used
29,260
## Insights: Post-Match Triage

### Vision

Replace the current “trust/story/notes” feed with a coaching dashboard that answers one question: “What should I fix before the next queue?” Trust metadata becomes supporting context, not the main content. The tab should rank problems by impact, confidence, and controllability, then show the user a short timeline-backed explanation and one concrete practice action.

### Layout

Single scroll view, 750-800px content width, built with existing `CreateFrame` and `ns.Widgets`. Top area is a compact two-column summary: left side shows the primary coaching callout, right side shows match context and data quality. Below that, use stacked sections with stable card heights and no extra severity bars between cards. Color is reserved for priority and confidence badges.

### Core sections

- **Next Queue Focus**: one large card with the highest-value recommendation. Shows title, “why it mattered,” “what to do next,” and 2-3 evidence chips. Example: “Trade earlier into stun chains. You died in CC with defensive available; first defensive came 4.8s later than your baseline.”

- **Fight Timeline Read**: compact horizontal sequence: opener, first go, first defensive, first CC chain, death or match end. Each node is labeled “good,” “late,” “missing,” or “unknown.” This replaces the vague Fight Story sentence.

- **Pressure / Survival / Control Scoreboard**: three columns comparing current match vs personal baseline, matchup baseline, and build baseline where available. Each metric shows delta, sample count, and confidence.

- **Matchup Plan**: opponent spec card with historical win rate, common failure pattern, and one counter-action. This folds Strategy Spotlight and Matchup Memory into a usable matchup module.

- **Evidence Drawer**: collapsed-by-default list of all generated suggestions, filterable by Offense, Defense, CC, Matchup, Consistency. This keeps detail available without making the main view a garbage feed.

- **Practice Plan**: 1-3 drills generated from recurring reason codes, not single-session noise. Example: “First defensive drill: review matches where `DEFENSIVE_DRIFT`, `DIED_WITH_DEFENSIVES`, or `REACTIVE_DEFENSIVE_LATE` appeared twice this week.”

### Data wiring

Priority = severity × confidence × recurrence × controllability. Current `suggestions[]` provide reason codes, evidence, severity, effort, and confidence. Timeline uses `rawEvents`, `cooldowns`, `auras`, `spells`, and CC-specific suggestions when CLEU is available. When CLEU is restricted, the timeline shows only reliable anchors from scoreboard totals, cooldown summaries, arena roster, and metric provenance. Baselines come from builds, contexts, opponents, specs, daily/weekly trends, and dummy benchmarks.

### Why this beats current

It leads with coaching value instead of import quality. It turns 30 reason codes into a ranked decision, shows when the addon is guessing, and separates “what happened” from “what to practice.” The user no longer reads eight flat cards and a confidence lecture; they get one focus, one timeline, one matchup plan, and optional evidence.

### Risks

Ranking must avoid overconfidence when Midnight restricts CLEU. Some sessions will only support scoreboard-level advice, so the UI needs explicit “unknown” states. The priority formula may need tuning with real match histories to avoid repeating the same generic recommendation.
